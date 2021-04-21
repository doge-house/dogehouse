defmodule Broth.SocketHandler do
  require Logger

  @type state :: %__MODULE__{
          awaiting_init: boolean(),
          user_id: String.t(),
          encoding: :etf | :json,
          compression: nil | :zlib
        }

  defstruct awaiting_init: true,
            user_id: nil,
            encoding: nil,
            compression: nil,
            callers: []

  @behaviour :cowboy_websocket

  ###############################################################
  ## initialization boilerplate

  @impl true
  def init(request, _state) do
    props = :cowboy_req.parse_qs(request)

    compression =
      case :proplists.get_value("compression", props) do
        p when p in ["zlib_json", "zlib"] -> :zlib
        _ -> nil
      end

    encoding =
      case :proplists.get_value("encoding", props) do
        "etf" -> :etf
        _ -> :json
      end

    state = %__MODULE__{
      awaiting_init: true,
      user_id: nil,
      encoding: encoding,
      compression: compression,
      callers: get_callers(request)
    }

    {:cowboy_websocket, request, state}
  end

  @auth_timeout Application.compile_env(:kousa, :websocket_auth_timeout)

  @impl true
  def websocket_init(state) do
    Process.send_after(self(), :auth_timeout, @auth_timeout)
    Process.put(:"$callers", state.callers)

    {:ok, state}
  end

  #######################################################################
  ## API

  @typep command :: :cow_ws.frame | {:shutdown, :normal}
  @typep call_result :: {[command], state}

  # exit
  def exit(pid), do: send(pid, :exit)
  @spec exit_impl(state) :: call_result
  defp exit_impl(state) do
    # note the remote webserver will then close the connection.  The
    # second command forces a shutdown in case the client is a jerk and
    # tries to DOS us by holding open connections.
    {[{:close, 1000, "killed by server"}, shutdown: :normal], state}
  end

  # auth timeout
  @spec auth_timeout_impl(state) :: call_result
  defp auth_timeout_impl(state) do
    if state.awaiting_init do
      {[{:close, 1000, "authorization"}, shutdown: :normal], state}
    else
      {[], state}
    end
  end

  # transitional remote_send message
  def remote_send(socket, message), do: send(socket, {:remote_send, message})

  @spec remote_send_impl(Kousa.json, state) :: call_result
  defp remote_send_impl(message, state) do
    {[prepare_socket_msg(message, state)], state}
  end

  @special_cases ~w(
    block_user_and_from_room
    fetch_follow_list
    join_room_and_get_info
  )

  @impl true
  def websocket_handle({:text, "ping"}, state), do: {[text: "pong"], state}
  def websocket_handle({:text, command_json}, state) do
    with {:ok, message_map!} <- Jason.decode(command_json),
         # temporary trap mediasoup direct commands
         %{"op" => <<not_at>> <> _} when not_at != ?@ <- message_map!,
         # temporarily trap special cased commands
         %{"op" => not_special_case} when not_special_case not in @special_cases <- message_map!,
         # translation from legacy maps to new maps
         message_map! = Broth.Translator.translate_inbound(message_map!),
         {:ok, message = %{errors: nil}} <- validate(message_map!, state) do
      dispatch(message, state)
    else
      # special cases: mediasoup operations
      msg = %{"op" => "@" <> _} ->
        dispatch_mediasoup_message(msg, state)

      # legacy special cases
      msg = %{"op" => special_case} when special_case in @special_cases ->
        Broth.LegacyHandler.process(msg, state)

      {:error, %Jason.DecodeError{}} ->
        {[{:close, 4001, "invalid input"}], state}

      # error validating the inner changeset.
      {:ok, error} ->
        reply =
          error
          |> Map.put(:operator, error.inbound_operator)
          |> prepare_socket_msg(state)

        {[reply], state}

      {:error, changeset = %Ecto.Changeset{}} ->
        reply = %{errors: Kousa.Utils.Errors.changeset_errors(changeset)}
        {[prepare_socket_msg(reply, state)], state}
    end
  end

  import Ecto.Changeset

  def validate(message, state) do
    message
    |> Broth.Message.changeset(state)
    |> apply_action(:validate)
  end

  def dispatch(message, state) do
    case message.operator.execute(message.payload, state) do
      close = {:close, _, _} ->
        {[close], state}

      {:error, changeset = %Ecto.Changeset{}} ->
        # hacky, we need to build a reverse lookup for the modules/operations.
        reply =
          message
          |> Map.merge(%{
            operator: message.inbound_operator,
            errors: Kousa.Utils.Errors.changeset_errors(changeset)
          })
          |> prepare_socket_msg(state)

        {[reply], state}

      {:error, err} when is_binary(err) ->
        reply =
          message
          |> wrap_error(%{message: err})
          |> prepare_socket_msg(state)

        {[reply], state}

      {:error, err} ->
        reply =
          message
          |> wrap_error(%{message: inspect(err)})
          |> prepare_socket_msg(state)

        {[reply], state}

      {:error, errors, new_state} ->
        reply =
          message
          |> wrap_error(errors)
          |> prepare_socket_msg(new_state)

        {[reply], new_state}

      {:noreply, new_state} ->
        {[], new_state}

      {:reply, payload, new_state} ->
        reply =
          message
          |> wrap(payload)
          |> prepare_socket_msg(new_state)

        {[reply], new_state}
    end
  end

  def wrap(message, payload = %{}) do
    %{message | operator: message.inbound_operator <> ":reply", payload: payload}
  end

  def wrap_error(message, error_map) do
    %{message | payload: %{}, errors: error_map, operator: message.inbound_operator}
  end

  defp dispatch_mediasoup_message(msg, state = %{user_id: user_id}) do
    with {:ok, room_id} <- Beef.Users.tuple_get_current_room_id(user_id) do
      voice_server_id = Onion.RoomSession.get(room_id, :voice_server_id)

      mediasoup_message =
        msg
        |> Map.put("d", msg["p"] || msg["d"])
        |> put_in(["d", "peerId"], user_id)
        |> put_in(["d", "roomId"], room_id)

      Onion.VoiceRabbit.send(voice_server_id, mediasoup_message)
    end

    # if this results in something funny because the user isn't in a room, we
    # will just swallow the result, it means that there is some amount of asynchrony
    # in the information about who is in what room.
    {:ok, state}
  end

  def prepare_socket_msg(data, state) do
    data
    |> encode_data(state)
    |> prepare_data(state)
  end

  defp encode_data(data, %{encoding: :etf}) do
    data
    |> Map.from_struct()
    |> :erlang.term_to_binary()
  end

  defp encode_data(data, %{encoding: :json}) do
    Jason.encode!(data)
  end

  defp prepare_data(data, %{compression: :zlib}) do
    z = :zlib.open()

    :zlib.deflateInit(z)
    data = :zlib.deflate(z, data, :finish)
    :zlib.deflateEnd(z)

    {:binary, data}
  end

  defp prepare_data(data, %{encoding: :etf}) do
    {:binary, data}
  end

  defp prepare_data(data, %{encoding: :json}) do
    {:text, data}
  end

  ########################################################################
  # helper functions

  if Mix.env() == :test do
    defp get_callers(request) do
      request_bin = :cowboy_req.header("user-agent", request)

      List.wrap(
        if is_binary(request_bin) do
          request_bin
          |> Base.decode16!()
          |> :erlang.binary_to_term()
        end
      )
    end
  else
    defp get_callers(_), do: []
  end

  # ROUTER

  @impl true
  def websocket_info(:exit, state), do: exit_impl(state)
  def websocket_info(:auth_timeout, state), do: auth_timeout_impl(state)
  def websocket_info({:remote_send, message}, state), do: remote_send_impl(message, state)

end
