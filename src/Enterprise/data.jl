# Tabs and data controls: TabControl, ListView, GridView, ComboBox.

# ---- TabControl -----------------------------------------------------------

"""
    Enterprise.TabControl(; tabs, selected, children, on_change)

A Win7 tab control: raised inactive tabs, a selected tab merging into the page,
and one content child per tab. `selected` is an `Observable{Int}`.
"""
function TabControl(; tabs = Any[], selected, children = Any[],
                    on_change = () -> nothing, fill = false)
    selected isa Observable ||
        error("Enterprise.TabControl needs an `Observable` as its `selected` prop")
    t = theme()
    selected = @use selected
    kids = flat_children(children)
    # Tab widths match the Pressable box math (padding_x 12 on both sides —
    # the 1px border paints over the box edge and is not measured) so the seam
    # patch can be positioned exactly.
    tab_w(text) = text_width(string(text), t) + 24
    tabbar = Any[]
    seam_x = 0.0
    seam_w = 0.0
    xoff = 0.0
    for (i, tab) in enumerate(tabs)
        active = selected[] == i
        w = tab_w(tab)
        if active
            seam_x = xoff
            seam_w = w
        end
        xoff += w + 2 # 2px gap between tabs
        push!(tabbar, @rock Pressable(
            text_element(tab; color = t.colors.text,
                         size = t.metrics.font_size, font = t.font);
            on_press = () -> (selected[] = i; on_change()),
            background = active ? t.gradients.tab_selected : t.gradients.tab,
            hover_background = active ? t.gradients.tab_selected : t.gradients.button_hover,
            pressed_background = active ? t.gradients.tab_selected : t.gradients.button_pressed,
            border_color = t.colors.border, border_width = 1,
            radius = (t.metrics.control_radius, t.metrics.control_radius, 0, 0),
            height = active ? t.metrics.tab_height + 2 : t.metrics.tab_height,
            padding_x = 12, padding_y = 0,
            direction = :row, align = :center, justify = :center))
    end
    # The raised page paints a top border under the tabs; paint the selected
    # tab over the whole seam band (its early bottom ring, the blank raise row
    # below it and the page's top border slice) so the tab melts into the page,
    # keeping the tab's side borders and the page's side borders intact
    # (the bottom-aligned taller selected tab is what makes the seam visible).
    seam = Any[]
    if seam_w > 0
        push!(seam, @rock Box(;
            position = :absolute, x = seam_x + 1,
            y = t.metrics.tab_height, width = seam_w - 2, height = 3,
            background = t.colors.document))
    end
    content = length(kids) >= selected[] && selected[] >= 1 ? kids[selected[]] : nothing
    page = @rock Box(
        content;
        background = t.colors.document,
        border_color = t.colors.border, border_width = 1,
        padding = 12, direction = :column, gap = 6,
        fill = true, stretch_children = true)
    return Element(
        _BOX,
        props_dict(:direction => :column, :gap => 0, :align => :start,
                   :fill => fill),
        Any[(@rock Box(tabbar...; direction = :row, gap = 2, align = :end)),
            page,
            seam...],
    )
end

# ---- ListView -------------------------------------------------------------

list_item_parts(item) = item isa Tuple || item isa Vector ?
    (string(item[1]), length(item) >= 2 ? item[2] : nothing) :
    (string(item), nothing)

list_selected(sel, i) = sel isa AbstractVector ? i in sel : sel == i

function list_select!(sel, i, multi)
    if multi
        values = collect(Int, sel isa AbstractVector ? sel : Int[])
        i in values ? filter!(!=(i), values) : push!(values, i)
        sel isa Observable && (sel[] = sort(values))
    else
        sel isa Observable && (sel[] = i)
    end
    return nothing
end

"""
    Enterprise.ListView(; items, selected, on_select, multi, checkboxes,
                        icons, width = 320, height = 240)

A white list with optional icons, checkboxes and multi-selection.
`selected` is an `Observable{Int}` (0 = none) or, with `multi = true`, an
`Observable{Vector{Int}}`.
"""
function ListView(; items = Any[], selected, on_select = (i) -> nothing,
                  multi = false, checkboxes = false, icons = false,
                  width = 320, height = 240)
    selected isa Observable ||
        error("Enterprise.ListView needs an `Observable` as its `selected` prop")
    t = theme()
    selected = @use selected
    multi = multi || selected[] isa AbstractVector
    rows = Any[]
    for (i, item) in enumerate(items)
        label, icon = list_item_parts(item)
        on = list_selected(selected[], i)
        leading = Any[]
        checkboxes && push!(leading, @rock Box(
            on ? text_element("✓"; color = t.colors.text,
                              size = t.metrics.font_size, font = t.font) : nothing;
            width = 16, height = t.metrics.row_height,
            direction = :row, align = :center, justify = :center))
        icons && push!(leading, @rock Box(
            icon === nothing ?
                Icon("file"; size = 12,
                     color = on ? t.colors.selection_text : t.colors.text,
                     font = t.font) :
                Icon(string(icon); size = 12,
                     color = on ? t.colors.selection_text : t.colors.text,
                     font = t.font);
            width = 18, height = t.metrics.row_height,
            direction = :row, align = :center, justify = :center))
        push!(leading, text_element(label;
            color = on ? t.colors.selection_text : t.colors.text,
            size = t.metrics.font_size, font = t.font))
        push!(rows, @rock Pressable(
            leading...;
            on_press = () -> begin
                list_select!(selected, i, multi)
                on_select(i)
            end,
            background = on ? t.colors.selection : nothing,
            hover_background = on ? t.colors.selection : t.colors.hot,
            pressed_background = on ? t.colors.selection : t.colors.hot_border,
            height = t.metrics.row_height,
            padding_x = 3, padding_y = 0,
            direction = :row, align = :center, gap = 2, fill = true))
    end
    body = @rock ScrollView(
        rows...;
        position = :absolute, fill = true,
        scrollbar = true, scrollbar_width = t.metrics.scrollbar,
        scrollbar_track = t.colors.scrollbar_track,
        scrollbar_thumb = t.gradients.scrollbar_thumb,
        scrollbar_border = t.colors.scrollbar_border,
        scrollbar_radius = 2,
        padding = 2, gap = 0, direction = :column, align = :start)
    return Element(
        _BOX,
        props_dict(:width => width, :height => height,
                   :background => t.colors.document,
                   :border_color => t.colors.input_border,
                   :border_width => 1, :bevel => :sunken,
                   :padding => 0, :direction => :column),
        Any[body],
    )
end

# ---- GridView -------------------------------------------------------------

grid_column(col) = begin
    label = string(col[1])
    width = length(col) >= 2 ? float(col[2]) : 100.0
    align = length(col) >= 3 ? Symbol(col[3]) : :left
    (label, width, align)
end

function grid_cell(value, width, align, t::Theme; header = false)
    color = header ? t.colors.text : t.colors.text
    return @rock Box(
        text_element(value; color = color, size = t.metrics.font_size, font = t.font);
        width = width, height = header ? t.metrics.header_height : t.metrics.row_height,
        padding_x = 3, padding_y = 0,
        direction = :row, align = :center,
        justify = align === :right ? :end : align === :center ? :center : :start)
end

"""
    Enterprise.GridView(; columns, rows, selected, on_select, sortable = true,
                        width = 460, height = 240, fill = false)

A grid with a gradient header, gridlines, selection, sorting and a scrollbar.
`columns` is a vector of `(label, width)` or `(label, width, align)` tuples;
`rows` is a vector of tuples/vectors. `selected` is an `Observable{Int}`.
With `fill = true` the last column stretches so the grid spans `width`.
"""
function GridView(; columns = Any[], rows = Any[], selected,
                  on_select = (i) -> nothing, sortable = true,
                  width = 460, height = 240, fill = false)
    selected isa Observable ||
        error("Enterprise.GridView needs an `Observable` as its `selected` prop")
    t = theme()
    selected = @use selected
    sort_col = @use Observable(0)
    sort_desc = @use Observable(false)
    cols = [grid_column(c) for c in columns]
    if fill && length(cols) >= 2
        fixed = sum(w for (_, w, _) in cols[1:length(cols)-1]; init = 0.0)
        last_label, _, last_align = cols[end]
        cols = [cols[1:length(cols)-1]...,
                (last_label, max(width - 2 - fixed, 40.0), last_align)]
    end
    order = collect(1:length(rows))
    if sortable && sort_col[] >= 1 && sort_col[] <= length(cols) && !isempty(rows)
        key(i) = begin
            row = rows[i]
            v = row isa Tuple || row isa Vector ?
                (length(row) >= sort_col[] ? row[sort_col[]] : "") : row
            string(v)
        end
        sort!(order; by = key, rev = sort_desc[])
    end
    header_cells = Any[]
    for (i, (label, cw, align)) in enumerate(cols)
        marker = sort_col[] == i ? (sort_desc[] ? " ▼" : " ▲") : ""
        cell = grid_cell(label * marker, cw, align, t; header = true)
        if sortable
            cell = @rock Pressable(
                cell;
                on_press = () -> begin
                    if sort_col[] == i
                        sort_desc[] = !sort_desc[]
                    else
                        sort_col[] = i
                        sort_desc[] = false
                    end
                end,
                background = t.gradients.grid_header,
                hover_background = t.colors.hot,
                height = t.metrics.header_height,
                padding = 0, direction = :row, align = :center)
        end
        push!(header_cells, cell)
    end
    header = @rock Box(header_cells...;
        height = t.metrics.header_height,
        background = t.gradients.grid_header,
        border_color = t.colors.border, border_width = 1,
        direction = :row, align = :center, fill = true)
    body_rows = Any[]
    for (display_index, row_index) in enumerate(order)
        row = rows[row_index]
        cells = Any[]
        on = selected[] == row_index
        for (ci, (_, cw, align)) in enumerate(cols)
            value = row isa Tuple || row isa Vector ?
                    (length(row) >= ci ? row[ci] : "") : (ci == 1 ? row : "")
            push!(cells, grid_cell(value, cw, align, t))
        end
        push!(body_rows, @rock Pressable(
            cells...;
            on_press = () -> (selected[] = row_index; on_select(row_index)),
            background = on ? t.colors.selection : (isodd(display_index) ? t.colors.document : "#FAFAFA"),
            hover_background = on ? t.colors.selection : t.colors.hot,
            pressed_background = on ? t.colors.selection : t.colors.hot_border,
            height = t.metrics.row_height,
            border_color = t.colors.grid_line, border_width = 1,
            padding = 0, direction = :row, align = :center, fill = true))
    end
    body = @rock ScrollView(
        body_rows...;
        position = :absolute, x = 0, y = t.metrics.header_height,
        width = width, height = max(height - t.metrics.header_height, 0),
        scrollbar = true, scrollbar_width = t.metrics.scrollbar,
        scrollbar_track = t.colors.scrollbar_track,
        scrollbar_thumb = t.gradients.scrollbar_thumb,
        scrollbar_border = t.colors.scrollbar_border,
        scrollbar_radius = 2,
        padding = 0, gap = 0, direction = :column, align = :start)
    return Element(
        _BOX,
        props_dict(:width => width, :height => height,
                   :background => t.colors.document,
                   :border_color => t.colors.input_border,
                   :border_width => 1, :bevel => :sunken,
                   :padding => 0, :direction => :column),
        Any[header, body],
    )
end

# ---- ComboBox -------------------------------------------------------------

"""
    Enterprise.ComboBox(; items, selected, on_change, width = 160,
                        editable = false)

A sunken combo field with a raised drop button. The options list opens as
its own borderless OS window (a popup of the owner window) anchored under
the field, so it is never clipped by the combo box, an ancestor box or the
edge of the window — a long item list extends past the window and scrolls
inside a capped popup. `selected` is an `Observable{Int}`. Editable text
entry is not implemented; pass `editable = false`.
"""
function ComboBox(; items = Any[], selected, on_change = () -> nothing,
                  width = 160, editable = false)
    selected isa Observable ||
        error("Enterprise.ComboBox needs an `Observable` as its `selected` prop")
    editable && error("Enterprise.ComboBox does not support editable input yet")
    t = theme()
    selected = @use selected
    open = @use Observable(false)
    # The dropdown anchor, in owner-window client coordinates. Event
    # callbacks only see placed fiber geometry (the render spec has no
    # rects), so the toggle callback resolves the field rect and stores the
    # anchor here before the popup window mounts.
    popup_x = @use Ref(0.0)
    popup_y = @use Ref(0.0)
    labels = [string(i) for i in items]
    sel = clamp(selected[], 1, max(length(labels), 1))
    value = isempty(labels) ? "" : labels[sel]

    self = use_fiber()
    field_rect() = begin
        for c in self.children
            c.kind === _PRESSABLE && return c.rect
            for cc in c.children
                cc.kind === _PRESSABLE && return cc.rect
            end
        end
        return (0.0, 0.0, 0.0, 0.0)
    end
    # Decide on the render-time open state: while the popup is open,
    # `close_open_menus!` already flips `open` off between press and
    # release, so a plain `!open[]` toggle would instantly reopen it.
    was_open = open[]
    open_dropdown!() = begin
        x, y, _, h = field_rect()
        popup_x[] = x
        popup_y[] = y + h
        open[] = true
        return nothing
    end
    toggle! = () -> was_open ? (open[] = false) : open_dropdown!()

    drop = @rock Pressable(
        text_element("▼"; color = t.colors.text,
                     size = 9, font = t.font);
        on_press = toggle!,
        position = :absolute, anchor = :top_right, x = 0, y = 1,
        width = 18, height = t.metrics.input_height - 2,
        background = t.gradients.input_button,
        border_color = t.colors.border, border_width = 1,
        radius = 0, direction = :row, align = :center, justify = :center)
    field = @rock Pressable(
        (@rock Box(
            text_element(value; color = t.colors.text,
                         size = t.metrics.font_size, font = t.font);
            position = :absolute, x = 5, y = 4,
            # The entry is clipped before the drop button, so a long entry
            # does not run under it.
            width = max(width - 23, 0), overflow = :hidden)),
        drop;
        on_press = toggle!,
        background = t.colors.input,
        hover_background = t.colors.input,
        # The text is clipped to the field, so a long entry does not run over
        # the border when the field is squeezed.
        overflow = :hidden,
        border_color = was_open ? t.colors.focus : t.colors.input_border,
        border_width = 1, bevel = :sunken,
        bevel_light = t.colors.border_light,
        bevel_dark = t.colors.border_dark,
        radius = 2, width = width, height = t.metrics.input_height,
        padding = 0, direction = :row, align = :center)

    row_h = t.metrics.row_height
    full_h = 4 + length(labels) * row_h
    max_h = 300
    popup_h = min(full_h, max_h)
    capped = full_h > max_h
    # The scrolling rows box draws its scrollbar inside its right edge, so
    # capped lists leave room for it.
    entries_width = capped ? max(width - 4 - t.metrics.scrollbar, 0) :
                    width - 4
    entries = Any[]
    for i in eachindex(labels)
        push!(entries, @rock Pressable(
            text_element(labels[i];
                         color = i == sel ? t.colors.selection_text :
                                 t.colors.text,
                         size = t.metrics.font_size, font = t.font);
            on_press = () -> begin
                selected[] = i
                open[] = false
                on_change()
            end,
            background = i == sel ? t.colors.selection : nothing,
            hover_background = i == sel ? t.colors.selection : t.colors.hot,
            width = entries_width, height = row_h,
            padding_x = 3, padding_y = 0,
            direction = :row, align = :center))
    end
    if capped
        # Long lists scroll: the tagged width leaves room for the scrollbar
        # that the box draws inside its right edge.
        rows = @rock Box(entries...;
            width = max(width - 4 - t.metrics.scrollbar, 0),
            height = popup_h - 4, direction = :column, gap = 0,
            scroll = true, scrollbar = true,
            scrollbar_width = t.metrics.scrollbar,
            scrollbar_track = t.colors.scrollbar_track,
            scrollbar_thumb = t.gradients.scrollbar_thumb,
            scrollbar_border = t.colors.scrollbar_border,
            scrollbar_radius = 2)
    else
        rows = @rock Box(entries...;
            width = width - 4, height = popup_h - 4,
            direction = :column, gap = 0)
    end
    popup = open[] ? (@rock Window(
        @rock Box(rows;
            width = width, height = popup_h,
            background = t.colors.document,
            border_color = t.colors.border, border_width = 1,
            bevel = :raised, radius = 0,
            padding = 2, direction = :column, gap = 0);
        position = :manual, x = Int(popup_x[]), y = Int(popup_y[]),
        width = width, height = popup_h,
        popup = true, menu_open = open)) : nothing

    return Element(
        _BOX,
        props_dict(:width => width, :height => t.metrics.input_height,
                   :direction => :column),
        Any[field, popup],
    )
end
