defmodule TeslaMateWeb.SignInLive.Index do
  use TeslaMateWeb, :live_view

  import Core.Dependency, only: [call: 3]
  alias TeslaMate.{Auth, Api}

  @impl true
  def mount(_params, %{"locale" => locale}, socket) do
    if connected?(socket), do: Gettext.put_locale(locale)

    assigns = %{
      api: get_api(socket),
      page_title: gettext("Sign in"),
      error: nil,
      task: nil,
      state: {:credentials, Auth.change_credentials()}
    }

    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event("validate", %{"credentials" => c}, %{assigns: %{state: {:credentials, _}}} = s) do
    changeset =
      c
      |> Auth.change_credentials()
      |> Map.put(:action, :update)

    {:noreply, assign(s, state: {:credentials, changeset}, error: nil)}
  end

  def handle_event("validate", %{"mfa" => mfa}, %{assigns: %{state: {:mfa, data}}} = socket) do
    {_, devices, ctx} = data

    changeset =
      mfa
      |> mfa_changeset()
      |> Map.put(:action, :update)

    task =
      if changeset.valid? do
        %{passcode: passcode, device_id: device_id} = Ecto.Changeset.apply_changes(changeset)

        Task.async(fn ->
          call(socket.assigns.api, :sign_in, [device_id, passcode, ctx])
        end)
      end

    {:noreply, assign(socket, state: {:mfa, {changeset, devices, ctx}}, task: task, error: nil)}
  end

  def handle_event("sign_in", _params, %{assigns: %{state: {:credentials, changeset}}} = socket) do
    credentials = Ecto.Changeset.apply_changes(changeset)

    task =
      Task.async(fn ->
        call(socket.assigns.api, :sign_in, [credentials])
      end)

    {:noreply, assign(socket, task: task)}
  end

  @impl true
  def handle_info({ref, result}, %{assigns: %{task: %Task{ref: ref}}} = socket) do
    Process.demonitor(ref, [:flush])

    case result do
      :ok ->
        Process.sleep(250)
        {:noreply, redirect_to_carlive(socket)}

      {:ok, {:mfa, devices, ctx}} ->
        devices = Enum.map(devices, fn %{"name" => name, "id" => id} -> {name, id} end)
        {:noreply, assign(socket, state: {:mfa, {mfa_changeset(), devices, ctx}}, task: nil)}

      {:error, %TeslaApi.Error{} = e} ->
        {:noreply, assign(socket, error: Exception.message(e), task: nil)}
    end
  end

  defp mfa_changeset(attrs \\ %{}) do
    import Ecto.Changeset

    {%{}, %{passcode: :string, device_id: :string}}
    |> cast(attrs, [:passcode, :device_id])
    |> validate_required([:passcode, :device_id])
    |> validate_length(:passcode, is: 6)
    |> validate_format(:passcode, ~r/\d{6}/)
  end

  defp get_api(socket) do
    case get_connect_params(socket) do
      %{api: api} -> api
      _ -> Api
    end
  end

  defp redirect_to_carlive(socket) do
    socket
    |> put_flash(:success, gettext("Signed in successfully"))
    |> redirect(to: Routes.car_path(socket, :index))
  end
end
