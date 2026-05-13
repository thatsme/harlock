# Contacts — a multi-pane TUI showcasing Harlock v0.2:
#
#   - vbox / hbox / box layout with titled borders
#   - table (used as a list) with row selection and focus highlighting
#   - text_input for search and form fields
#   - overlay + focus_trap for a modal "add / edit" dialog
#   - focus traversal via Tab / Shift-Tab between widgets
#   - Cmd executor for a fake async "save" with a delay
#   - custom theme overriding focus / selection / header colors
#
# Run from the project root:
#
#   ./scripts/run.sh contacts
#
# Shortcuts (also shown in the bottom bar):
#
#   Tab / Shift-Tab — cycle focus between widgets
#   Up / Down       — when the list is focused, move the selection
#   a               — open the "new contact" modal (when list is focused)
#   e               — open the "edit contact" modal (when list is focused)
#   d               — delete the selected contact (when list is focused)
#   Enter (modal)   — save the contact (with a brief simulated delay)
#   Esc (modal)     — close the modal without saving
#   q               — quit (when list is focused)

defmodule ContactsApp do
  use Harlock.App

  alias Harlock.Focus
  alias Harlock.TextBuffer

  @initial_contacts [
    %{id: 1, name: "Alice Wong",   email: "alice@example.com",   phone: "+1 555 0100"},
    %{id: 2, name: "Bob Martin",   email: "bob@example.com",     phone: "+1 555 0101"},
    %{id: 3, name: "Charlie Kim",  email: "charlie@example.com", phone: "+1 555 0102"},
    %{id: 4, name: "Diana Patel",  email: "diana@example.com",   phone: "+1 555 0103"},
    %{id: 5, name: "Erik Hansen",  email: "erik@example.com",    phone: "+1 555 0104"}
  ]

  def init(_) do
    %{
      contacts: @initial_contacts,
      next_id: length(@initial_contacts) + 1,
      filter: "",
      filter_cursor: 0,
      focused_id: 1,
      modal: nil,
      status: "Ready",
      saving?: false
    }
  end

  # ----- update -----

  # Ctrl+C: unconditional quit. Always available regardless of focus, so
  # you can never get stuck inside an input field.
  def update({:key, {:char, ?c}, [:ctrl]}, _model), do: :quit

  # The save Cmd finishes.
  def update({:contact_saved, contact}, model) do
    contacts = upsert(model.contacts, contact)

    %{
      model
      | contacts: contacts,
        modal: nil,
        saving?: false,
        status: "Saved #{contact.name}",
        focused_id: contact.id
    }
  end

  # Modal: cancel.
  def update({:key, :escape, []}, %{modal: m} = model) when not is_nil(m) do
    %{model | modal: nil, status: "Cancelled"}
  end

  # Modal: submit on Enter from any field.
  def update({:key, :enter, []}, %{modal: m} = model) when not is_nil(m) do
    start_save(model, m)
  end

  # Modal: route key events to the focused text_input field.
  def update({:key, _, _} = event, %{modal: m} = model) when not is_nil(m) do
    case Focus.current() do
      field when field in [:modal_name, :modal_email, :modal_phone] ->
        {value_key, cursor_key} = modal_field_keys(field)
        value = Map.fetch!(m, value_key)
        cursor = Map.fetch!(m, cursor_key)

        case TextBuffer.apply_key(event, value, cursor) do
          {:edit, v, c} ->
            new_modal = m |> Map.put(value_key, v) |> Map.put(cursor_key, c)
            %{model | modal: new_modal}

          _ ->
            model
        end

      _ ->
        model
    end
  end

  # No-modal shortcuts — only active when the list is focused, so typing
  # 'q' or 'a' into the search input doesn't accidentally trigger them.
  def update({:key, {:char, ?q}, []}, model) do
    if Focus.current() == :contact_list, do: :quit, else: search_key(model, {:char, ?q})
  end

  def update({:key, {:char, ?a}, []}, model) do
    if Focus.current() == :contact_list,
      do: open_new_modal(model),
      else: search_key(model, {:char, ?a})
  end

  def update({:key, {:char, ?e}, []}, model) do
    if Focus.current() == :contact_list,
      do: open_edit_modal(model),
      else: search_key(model, {:char, ?e})
  end

  def update({:key, {:char, ?d}, []}, model) do
    if Focus.current() == :contact_list,
      do: delete_focused(model),
      else: search_key(model, {:char, ?d})
  end

  # List navigation when the list is focused.
  def update({:key, :down, []}, model) do
    case Focus.current() do
      :contact_list -> move_focus(model, +1)
      _ -> search_key(model, :down)
    end
  end

  def update({:key, :up, []}, model) do
    case Focus.current() do
      :contact_list -> move_focus(model, -1)
      _ -> search_key(model, :up)
    end
  end

  # Catch-all: route remaining key events to the search input when it has focus.
  def update({:key, _, _} = event, model) do
    case Focus.current() do
      :search ->
        {:key, key, mods} = event

        case TextBuffer.apply_key({:key, key, mods}, model.filter, model.filter_cursor) do
          {:edit, v, c} -> %{model | filter: v, filter_cursor: c}
          _ -> model
        end

      _ ->
        model
    end
  end

  def update(_event, model), do: model

  # ----- view -----

  def view(model) do
    background =
      vbox(
        constraints: [length: 3, fill: 1, length: 1],
        children: [
          search_bar(model),
          main_pane(model),
          status_bar(model)
        ]
      )

    case model.modal do
      nil ->
        background

      modal ->
        overlay(
          child: background,
          over: modal_form(modal),
          width: 50,
          height: 9,
          focus_trap: true
        )
    end
  end

  defp search_bar(model) do
    focused? = Focus.current() == :search

    box(
      title: if(focused?, do: "● Search", else: "  Search"),
      border: if(focused?, do: :double, else: :rounded),
      border_style:
        if(focused?,
          do: %Style{fg: :yellow},
          else: %Style{fg: :bright_black}
        ),
      padding: {0, 1},
      child:
        text_input(
          value: model.filter,
          cursor: model.filter_cursor,
          placeholder: "Tab to leave, type to filter…",
          focusable: :search
        )
    )
  end

  defp main_pane(model) do
    hbox(
      constraints: [length: 30, fill: 1],
      children: [list_pane(model), detail_pane(model)]
    )
  end

  defp list_pane(model) do
    visible = visible_contacts(model)
    focused? = Focus.current() == :contact_list

    box(
      title:
        if(focused?,
          do: "● Contacts (#{length(visible)})",
          else: "  Contacts (#{length(visible)})"
        ),
      border: if(focused?, do: :double, else: :rounded),
      border_style:
        if(focused?,
          do: %Style{fg: :yellow},
          else: %Style{fg: :bright_black}
        ),
      padding: {0, 1},
      child:
        table(
          columns: [column(width: {:fill, 1}, render: &row_label(&1, model.focused_id))],
          rows: visible,
          row_id: & &1.id,
          focused_row: model.focused_id,
          show_header: false,
          focusable: :contact_list
        )
    )
  end

  defp row_label(contact, focused_id) do
    if contact.id == focused_id, do: "▶ " <> contact.name, else: "  " <> contact.name
  end

  defp detail_pane(model) do
    case Enum.find(model.contacts, &(&1.id == model.focused_id)) do
      nil ->
        box(
          title: "Details",
          border: :rounded,
          border_style: %Style{fg: :bright_black},
          padding: 1,
          child: text("No contact selected.")
        )

      contact ->
        box(
          title: "Details — #{contact.name}",
          border: :rounded,
          border_style: %Style{fg: :bright_black},
          padding: 1,
          child:
            vbox(
              constraints: [length: 1, length: 1, length: 1, length: 1, fill: 1],
              children: [
                text("Name:  #{contact.name}"),
                text("Email: #{contact.email}"),
                text("Phone: #{contact.phone}"),
                spacer(),
                text("[a] add  [e] edit  [d] delete", style: %Style{dim: true})
              ]
            )
        )
    end
  end

  defp status_bar(model) do
    focus_label =
      case Focus.current() do
        :search -> "search"
        :contact_list -> "list"
        :modal_name -> "modal: name"
        :modal_email -> "modal: email"
        :modal_phone -> "modal: phone"
        nil -> "—"
        other -> to_string(other)
      end

    left = if model.saving?, do: "saving…", else: model.status
    middle = "focus: #{focus_label}"
    right = "Tab cycle • ↑↓ nav • a/e/d • q quit"
    text(" #{pad_three(left, middle, right)}", style: %Style{reverse: true})
  end

  defp pad_three(left, middle, right) do
    total = 78
    used = String.length(left) + String.length(middle) + String.length(right)
    gap = max(1, div(total - used, 2))
    spaces = String.duplicate(" ", gap)
    left <> spaces <> middle <> spaces <> right
  end

  defp modal_form(m) do
    title =
      case m.mode do
        :new -> "New Contact"
        {:edit, _} -> "Edit Contact"
      end

    box(
      title: title,
      border: :double,
      border_style: %Style{fg: :yellow},
      padding: 1,
      child:
        vbox(
          constraints: [length: 1, length: 1, length: 1, length: 1, fill: 1, length: 1],
          children: [
            field_row("Name ", :name, m),
            field_row("Email", :email, m),
            field_row("Phone", :phone, m),
            spacer(),
            spacer(),
            text("[Enter] save   [Esc] cancel   [Tab] next field",
              style: %Style{dim: true}
            )
          ]
        )
    )
  end

  defp field_row(label, key, m) do
    {value_key, cursor_key} = modal_field_keys(:"modal_#{key}")

    hbox(
      constraints: [length: 7, fill: 1],
      children: [
        text(label <> ":"),
        text_input(
          value: Map.fetch!(m, value_key),
          cursor: Map.fetch!(m, cursor_key),
          focusable: :"modal_#{key}",
          placeholder: ""
        )
      ]
    )
  end

  # ----- helpers -----

  defp visible_contacts(%{contacts: contacts, filter: ""}), do: contacts

  defp visible_contacts(%{contacts: contacts, filter: filter}) do
    needle = String.downcase(filter)

    Enum.filter(contacts, fn c ->
      String.contains?(String.downcase(c.name), needle) or
        String.contains?(String.downcase(c.email), needle)
    end)
  end

  defp move_focus(model, delta) do
    visible = visible_contacts(model)
    ids = Enum.map(visible, & &1.id)

    case Enum.find_index(ids, &(&1 == model.focused_id)) do
      nil ->
        case ids do
          [first | _] -> %{model | focused_id: first}
          [] -> model
        end

      idx ->
        n = length(ids)
        new_idx = rem(idx + delta + n, n)
        %{model | focused_id: Enum.at(ids, new_idx)}
    end
  end

  defp open_new_modal(model) do
    %{
      model
      | modal: %{
          mode: :new,
          name: "",
          name_cursor: 0,
          email: "",
          email_cursor: 0,
          phone: "",
          phone_cursor: 0
        },
        status: "Adding new contact"
    }
  end

  defp open_edit_modal(model) do
    case Enum.find(model.contacts, &(&1.id == model.focused_id)) do
      nil ->
        model

      c ->
        %{
          model
          | modal: %{
              mode: {:edit, c.id},
              name: c.name,
              name_cursor: String.length(c.name),
              email: c.email,
              email_cursor: String.length(c.email),
              phone: c.phone,
              phone_cursor: String.length(c.phone)
            },
            status: "Editing #{c.name}"
        }
    end
  end

  defp delete_focused(%{contacts: [_one_left]} = model) do
    %{model | status: "Can't delete the last contact"}
  end

  defp delete_focused(model) do
    case Enum.find(model.contacts, &(&1.id == model.focused_id)) do
      nil ->
        model

      c ->
        remaining = Enum.reject(model.contacts, &(&1.id == c.id))
        next_focus = (List.first(remaining) || %{id: nil}).id
        %{model | contacts: remaining, focused_id: next_focus, status: "Deleted #{c.name}"}
    end
  end

  defp start_save(model, modal) do
    contact = build_contact_from_modal(modal, model.next_id)

    next_id =
      case modal.mode do
        :new -> model.next_id + 1
        _ -> model.next_id
      end

    cmd =
      Cmd.from(fn ->
        Process.sleep(200)
        contact
      end)
      |> Cmd.map(fn c -> {:contact_saved, c} end)

    {%{model | saving?: true, next_id: next_id, status: "Saving…"}, cmd}
  end

  defp build_contact_from_modal(modal, next_id) do
    id =
      case modal.mode do
        :new -> next_id
        {:edit, id} -> id
      end

    %{
      id: id,
      name: trim_or(modal.name, "(no name)"),
      email: trim_or(modal.email, "(no email)"),
      phone: trim_or(modal.phone, "(no phone)")
    }
  end

  defp trim_or(str, default) do
    case String.trim(str) do
      "" -> default
      s -> s
    end
  end

  defp upsert(contacts, contact) do
    case Enum.find_index(contacts, &(&1.id == contact.id)) do
      nil -> contacts ++ [contact]
      idx -> List.replace_at(contacts, idx, contact)
    end
  end

  defp search_key(model, key) do
    if Focus.current() == :search do
      case TextBuffer.apply_key({:key, key, []}, model.filter, model.filter_cursor) do
        {:edit, v, c} -> %{model | filter: v, filter_cursor: c}
        _ -> model
      end
    else
      model
    end
  end

  defp modal_field_keys(:modal_name), do: {:name, :name_cursor}
  defp modal_field_keys(:modal_email), do: {:email, :email_cursor}
  defp modal_field_keys(:modal_phone), do: {:phone, :phone_cursor}
end

theme = %Harlock.Theme{
  header: %Harlock.Render.Style{bold: true, fg: :cyan},
  focus: %Harlock.Render.Style{reverse: true, fg: :yellow},
  selection: %Harlock.Render.Style{bg: :blue, fg: :white},
  border: %Harlock.Render.Style{fg: :bright_black}
}

case System.argv() do
  ["--run"] -> Harlock.run(ContactsApp, nil, theme: theme)
  _ -> :ok
end
