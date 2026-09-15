# Run with:
#   ./scripts/run.sh contacts
#
# or directly:
#   mix run examples/contacts.exs --run
#
# Not from an IEx prompt: IEx's terminal driver reads the same tty, and the app
# would not receive keystrokes.
#
# A contact manager on a search box, a list, a detail pane and a dialog:
#
#   * text_input      — the search box filters as you type; the dialog's fields
#   * table           — the list; arrows or a click select a contact
#   * button          — Add / Edit / Delete under the details, Save / Cancel in
#                       the dialog
#   * checkbox        — "Favourite", shown as ★ in the list
#   * overlay         — the dialog, with focus_trap so Tab stays inside it
#   * box focus_proxy — a pane's border lights up while its widget has focus
#   * styled text     — the detail labels
#   * Cmd.from        — saving takes a moment, as it would against a server
#   * mouse           — click anything: rows, fields, buttons, the checkbox
#   * a custom theme  — the focus colour: the focused row, pane borders, buttons
#
# Keys (also in the bottom bar):
#
#   Tab / Shift-Tab   cycle focus
#   typing            filters the list while the search box has focus
#   Up / Down         move through the list while it has focus
#   Enter             edit the selected contact (list focused); in the
#                     dialog, save from any field
#   a / e / d         add, edit, delete (outside the search box and the dialog)
#   Esc               close the dialog without saving
#   q / Ctrl-C        quit (q outside the search box and the dialog)

defmodule ContactsApp do
  use Harlock.App

  alias Harlock.Focus

  @initial_contacts [
    %{
      id: 1,
      name: "Alice Wong",
      email: "alice@example.com",
      phone: "+1 555 0100",
      favourite: true
    },
    %{
      id: 2,
      name: "Bob Martin",
      email: "bob@example.com",
      phone: "+1 555 0101",
      favourite: false
    },
    %{
      id: 3,
      name: "Charlie Kim",
      email: "charlie@example.com",
      phone: "+1 555 0102",
      favourite: false
    },
    %{
      id: 4,
      name: "Diana Patel",
      email: "diana@example.com",
      phone: "+1 555 0103",
      favourite: true
    },
    %{
      id: 5,
      name: "Erik Hansen",
      email: "erik@example.com",
      phone: "+1 555 0104",
      favourite: false
    }
  ]

  @modal_fields [:modal_name, :modal_email, :modal_phone]

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

  # Ctrl-C quits from anywhere, so no widget can trap you.
  def update({:key, {:char, ?c}, [:ctrl]}, _model), do: :quit

  # The save Cmd finishes.
  def update({:contact_saved, contact}, model) do
    %{
      model
      | contacts: upsert(model.contacts, contact),
        modal: nil,
        saving?: false,
        status: "Saved #{contact.name}",
        focused_id: contact.id
    }
  end

  # -- the dialog --
  #
  # Every widget here is routed: edits arrive as {:harlock_edit, id, …}, Enter
  # and button presses as {:harlock_submit, id}, and the checkbox as
  # {:harlock_toggle, id, checked}. The clauses only say where values live.
  # While a save is in flight the dialog ignores further submits and Esc.

  def update(_event, %{saving?: true} = model) when model.modal != nil, do: model

  def update({:key, :escape, []}, %{modal: m} = model) when m != nil, do: cancel(model)

  def update({:harlock_submit, :modal_cancel}, %{modal: m} = model) when m != nil,
    do: cancel(model)

  def update({:harlock_submit, id}, %{modal: m} = model)
      when m != nil and id in [:modal_save | @modal_fields],
      do: start_save(model, m)

  def update({:harlock_edit, field, {value, cursor}}, %{modal: m} = model)
      when m != nil and field in @modal_fields do
    {value_key, cursor_key} = modal_field_keys(field)
    %{model | modal: m |> Map.put(value_key, value) |> Map.put(cursor_key, cursor)}
  end

  def update({:harlock_toggle, :modal_favourite, checked}, %{modal: m} = model) when m != nil,
    do: %{model | modal: %{m | favourite: checked}}

  # -- the main screen --

  def update({:harlock_edit, :search, {value, cursor}}, model),
    do: %{model | filter: value, filter_cursor: cursor}

  # The focused table routes Up / Down, and a click on a row, as a selection.
  def update({:harlock_select, :contact_list, id}, model), do: %{model | focused_id: id}

  def update({:harlock_submit, :add}, model), do: open_new_modal(model)
  def update({:harlock_submit, :edit}, model), do: open_edit_modal(model)
  def update({:harlock_submit, :delete}, model), do: delete_focused(model)

  # A table routes the arrows but not Enter, so Enter on the list is a raw key.
  def update({:key, :enter, []}, model) do
    if model.modal == nil and Focus.current() == :contact_list,
      do: open_edit_modal(model),
      else: model
  end

  # Shortcuts. Letters typed while a text input has focus are routed to it as
  # edits, so these clauses see them only when something else has focus; the
  # dialog's checkbox and buttons are the rest, hence the modal check.
  def update({:key, {:char, ?q}, []}, %{modal: nil}), do: :quit
  def update({:key, {:char, ?a}, []}, %{modal: nil} = model), do: open_new_modal(model)
  def update({:key, {:char, ?e}, []}, %{modal: nil} = model), do: open_edit_modal(model)
  def update({:key, {:char, ?d}, []}, %{modal: nil} = model), do: delete_focused(model)

  def update(_event, model), do: model

  # ----- view -----

  def view(model) do
    background =
      vbox(
        constraints: [length: 3, fill: 1, length: 1],
        children: [search_bar(model), main_pane(model), status_bar(model)]
      )

    case model.modal do
      nil ->
        background

      modal ->
        overlay(
          child: background,
          over: modal_form(modal, model.saving?),
          width: 50,
          height: 13,
          focus_trap: true
        )
    end
  end

  defp search_bar(model) do
    pane("Search", :search,
      child:
        text_input(
          value: model.filter,
          cursor: model.filter_cursor,
          placeholder: "type to filter, Tab to leave",
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

    pane("Contacts (#{length(visible)})", :contact_list,
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

  # A bordered pane drawn in the theme's focus style while `id` has focus.
  defp pane(title, id, opts) do
    box(
      [
        title: title,
        border: :rounded,
        border_style: %Style{fg: :bright_black},
        focus_proxy: id,
        padding: {0, 1}
      ] ++ opts
    )
  end

  # Table cells are plain strings, so the favourite marker is a character
  # rather than a styled run.
  defp row_label(contact, focused_id) do
    marker = if contact.id == focused_id, do: "▶ ", else: "  "
    star = if contact.favourite, do: " ★", else: ""
    marker <> contact.name <> star
  end

  defp detail_pane(model) do
    contact = Enum.find(model.contacts, &(&1.id == model.focused_id))

    box(
      title: if(contact, do: "Details — #{contact.name}", else: "Details"),
      border: :rounded,
      border_style: %Style{fg: :bright_black},
      padding: {1, 2},
      child:
        vbox(
          constraints: [fill: 1, length: 1],
          children: [details(contact), action_buttons()]
        )
    )
  end

  defp details(nil), do: text("No contact selected.", style: %Style{dim: true})

  defp details(contact) do
    label = &{String.pad_trailing(&1, 7), fg: :cyan}

    text([
      label.("Name"),
      {contact.name, bold: true},
      "\n",
      label.("Email"),
      contact.email,
      "\n",
      label.("Phone"),
      contact.phone,
      "\n\n"
      | if(contact.favourite, do: [{"★ Favourite", fg: :yellow}], else: [])
    ])
  end

  defp action_buttons do
    hbox(
      constraints: [length: 8, length: 9, length: 11, fill: 1],
      children: [
        button("Add", focusable: :add),
        button("Edit", focusable: :edit),
        button("Delete", focusable: :delete),
        spacer()
      ]
    )
  end

  defp status_bar(model) do
    left = if model.saving?, do: "Saving…", else: model.status

    statusbar(
      left: " #{left} · focus: #{focus_label(Focus.current())}",
      right: "Tab focus · a/e/d · q quit "
    )
  end

  defp focus_label(nil), do: "—"
  defp focus_label(:contact_list), do: "list"
  defp focus_label(id), do: id |> Atom.to_string() |> String.replace_prefix("modal_", "dialog: ")

  defp modal_form(m, saving?) do
    title =
      case m.mode do
        :new -> "New Contact"
        {:edit, _} -> "Edit Contact"
      end

    box(
      title: title,
      border: :double,
      border_style: %Style{fg: :yellow},
      padding: {1, 2},
      child:
        vbox(
          constraints: [
            length: 1,
            length: 1,
            length: 1,
            length: 1,
            length: 1,
            fill: 1,
            length: 1,
            length: 1
          ],
          children: [
            field_row("Name", :name, m),
            field_row("Email", :email, m),
            field_row("Phone", :phone, m),
            spacer(),
            checkbox([{"★ ", fg: :yellow}, "Favourite"],
              checked: m.favourite,
              focusable: :modal_favourite
            ),
            spacer(),
            hbox(
              constraints: [length: 13, length: 11, fill: 1],
              children: [
                button(if(saving?, do: "Saving…", else: "Save"), focusable: :modal_save),
                button("Cancel", focusable: :modal_cancel),
                spacer()
              ]
            ),
            text("Enter saves from a field · Esc cancels", style: %Style{dim: true})
          ]
        )
    )
  end

  defp field_row(label, key, m) do
    {value_key, cursor_key} = modal_field_keys(:"modal_#{key}")

    hbox(
      constraints: [length: 7, fill: 1],
      children: [
        text(label, style: %Style{fg: :cyan}),
        text_input(
          value: Map.fetch!(m, value_key),
          cursor: Map.fetch!(m, cursor_key),
          focusable: :"modal_#{key}"
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
          phone_cursor: 0,
          favourite: false
        },
        status: "Adding a contact"
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
              phone_cursor: String.length(c.phone),
              favourite: c.favourite
            },
            status: "Editing #{c.name}"
        }
    end
  end

  defp cancel(model), do: %{model | modal: nil, status: "Cancelled"}

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

    {%{model | saving?: true, next_id: next_id}, cmd}
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
      phone: trim_or(modal.phone, "(no phone)"),
      favourite: modal.favourite
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

  @doc false
  # The options `--run` starts the app with — the custom theme and the mouse.
  # The theme sets only the focus style, the one this screen draws with: every
  # pane sets its own border style, and the list has no header or selection.
  # The tests start it with these too, so a test cannot pass on an option the
  # real app never sets.
  def run_opts do
    theme = %Harlock.Theme{focus: %Style{reverse: true, fg: :yellow}}

    [theme: theme, mouse: true]
  end

  defp modal_field_keys(:modal_name), do: {:name, :name_cursor}
  defp modal_field_keys(:modal_email), do: {:email, :email_cursor}
  defp modal_field_keys(:modal_phone), do: {:phone, :phone_cursor}
end

# `--run` starts the app; without it the file only defines the module, which is
# how the tests load it.
case System.argv() do
  ["--run"] -> Harlock.run(ContactsApp, nil, ContactsApp.run_opts())
  _ -> :ok
end
