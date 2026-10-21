# Windows 7 / Winforms showcase for Rocks.Enterprise.
#
#   julia --project examples/enterprise.jl
#   SDL_VIDEODRIVER=dummy julia --project examples/enterprise.jl  # headless
#
# The app is a mock system utility: menu bar, toolbar, tabbed pages with group
# boxes and sunken inputs, list/grid views, progress and slider controls, a
# status bar, a modal message box and a context menu.

using Rocks
import Rocks.Enterprise
const E = Rocks.Enterprise

theme = Observable(E.light_theme())
tab = Observable(1)
check_splash = Observable(true)
check_updates = Observable(false)
check_telemetry = Observable(false)
radio_scale = Observable(1)
name = Observable("Ada Lovelace")
organization = Observable("Analytical Engines Ltd.")
department = Observable(2)
progress = Observable(0.64)
volume = Observable(0.35)
list_selected = Observable(1)
grid_selected = Observable(2)
recent_selected = Observable(0)
status_text = Observable("Ready")
message_open = Observable(false)
context_open = Observable(false)
message_result = Observable(:none)

const DEPARTMENTS = ["Engineering", "Research", "Operations", "Design"]

const FILE_ITEMS = [
    ("Documents", "folder"),
    ("Downloads", "folder"),
    ("Pictures", "folder"),
    ("Music", "folder"),
    ("notes.txt", "file"),
    ("roadmap.txt", "file"),
    ("budget.csv", "file"),
    ("logo.png", "file"),
    ("installer.exe", "file"),
    ("archive.zip", "file"),
    ("readme.md", "file"),
]

const GRID_COLUMNS = [("Name", 220), ("Type", 100), ("Size", 80, :right),
                      ("Modified", 110)]
const GRID_ROWS = [
    ("Documents", "Folder", "", "2026-10-14"),
    ("notes.txt", "Text", "12 KB", "2026-10-19"),
    ("roadmap.txt", "Text", "38 KB", "2026-10-18"),
    ("budget.csv", "CSV", "8 KB", "2026-10-12"),
    ("logo.png", "Image", "184 KB", "2026-10-08"),
    ("installer.exe", "Program", "4.2 MB", "2026-09-30"),
    ("archive.zip", "Archive", "2.8 MB", "2026-09-22"),
    ("readme.md", "Markdown", "3 KB", "2026-10-01"),
    ("settings.ini", "Config", "1 KB", "2026-10-16"),
    ("backup.bak", "Backup", "9.1 MB", "2026-09-11"),
]

const RECENT_ITEMS = [
    ("System report.txt", "file"),
    ("Q4 roadmap.txt", "file"),
    ("Design review notes.txt", "file"),
    ("budget.csv", "file"),
    ("logo.png", "file"),
    ("archive.zip", "file"),
    ("readme.md", "file"),
    ("settings.ini", "file"),
]

function Labeled(; label, control)
    label_box = @rock Box(@rock E.Label(label); width = 130)
    return @rock Row(label_box, control; gap = 8, align = :center)
end

function GeneralPage(; fill = false)
    t = theme[]
    name_field = @rock E.TextBox(text = name, width = 240)
    org_field = @rock E.TextBox(text = organization, width = 240)
    dept_combo = @rock E.ComboBox(items = DEPARTMENTS, selected = department,
                                  width = 240)
    system = @rock E.GroupBox(
        (@rock Labeled(; label = "Name:", control = name_field)),
        (@rock Labeled(; label = "Organization:", control = org_field)),
        (@rock Labeled(; label = "Department:", control = dept_combo));
        title = "System", caption_background = t.colors.window, fill = true)

    splash = @rock E.CheckBox(checked = check_splash,
                              label = "Show splash screen at startup")
    updates = @rock E.CheckBox(checked = check_updates,
                               label = "Check for updates automatically")
    telemetry = @rock E.CheckBox(checked = check_telemetry,
                                 label = "Send anonymous usage statistics")
    settings = @rock E.GroupBox(splash, updates, telemetry;
        title = "Settings", caption_background = t.colors.window, fill = true)

    small = @rock E.RadioButton(selected = radio_scale, value = 1,
                                label = "Small (100%)")
    medium = @rock E.RadioButton(selected = radio_scale, value = 2,
                                 label = "Medium (125%)")
    large = @rock E.RadioButton(selected = radio_scale, value = 3,
                                label = "Large (150%)")
    radio_row = @rock Row(small, medium, large; gap = 16, align = :center)
    scaling = @rock E.GroupBox(radio_row;
        title = "Display scaling", caption_background = t.colors.window,
        fill = true)

    progress_bar = @rock E.ProgressBar(value = progress, width = 420)
    volume_slider = @rock E.Slider(value = volume, width = 420, ticks = 10)
    progress_label = @rock E.Label("Background task progress")
    volume_label = @rock E.Label("Volume")
    progress_group = @rock E.GroupBox(
        progress_label, progress_bar, volume_label, volume_slider;
        title = "Status", caption_background = t.colors.window, fill = true)

    apply = @rock E.Button("Apply"; on_press = () -> status_text[] = "Settings applied")
    cancel = @rock E.Button("Cancel")
    ok = @rock E.Button("OK"; default = true,
                        on_press = () -> status_text[] = "Changes accepted")
    button_row = @rock Row(apply, cancel, ok; gap = 6, align = :center,
                           justify = :end, fill = true)

    recent = @rock E.ListView(items = RECENT_ITEMS, selected = recent_selected,
                              icons = true, width = 1040, height = 170)
    recent_group = @rock E.GroupBox(recent;
        title = "Recent items", caption_background = t.colors.window, fill = true)

    last_check = @rock E.Label("Last check: today at 09:42")
    version = @rock E.Label("Version: 7.4.1 (build 2026.10)")
    maintenance_note = @rock E.Label("No maintenance tasks are currently scheduled.")
    maintenance = @rock E.GroupBox(last_check, version, maintenance_note;
        title = "Maintenance", caption_background = t.colors.window, fill = true)

    # Reserve transparent space below the combo box so its popup is not covered
    # by later siblings. `pointer_events = :none` keeps the popup hittable.
    combo_space = @rock Box(; height = 90, pointer_events = :none)
    return @rock Column(settings, scaling, progress_group, system, combo_space,
                        recent_group, maintenance, button_row;
                        gap = 12, fill = fill)
end

function FilesPage(; fill = false)
    t = theme[]
    list = @rock E.ListView(items = FILE_ITEMS, selected = list_selected,
                            icons = true, width = 440, height = 300)
    grid = @rock E.GridView(columns = GRID_COLUMNS, rows = GRID_ROWS,
                            selected = grid_selected, width = 520, height = 300)
    browser = @rock E.Row(list, grid; gap = 12, align = :start)
    files = @rock E.GroupBox(browser;
        title = "Files and folders", caption_background = t.colors.window,
        fill = true)
    refresh = @rock E.Button("Refresh"; icon = "refresh",
        on_press = () -> status_text[] = "File list refreshed")
    details = @rock E.Button("Details")
    toolbar_row = @rock Row(refresh, details; gap = 6, align = :center)
    return @rock Column(files, toolbar_row; gap = 12, fill = fill)
end

function ControlsPage(; fill = false)
    t = theme[]
    normal = @rock E.Button("Normal")
    default = @rock E.Button("Default"; default = true)
    disabled = @rock E.Button("Disabled"; disabled = true)
    icon = @rock E.Button("Open"; icon = "open")
    buttons = @rock E.GroupBox(
        (@rock Row(normal, default, disabled, icon; gap = 6, align = :center));
        title = "Buttons", caption_background = t.colors.window, fill = true)

    tip_source = @rock E.Button("Hover for tooltip")
    tip = @rock E.ToolTip(tip_source; text = "A classic Win7 tooltip")
    link = @rock E.LinkLabel("Open documentation";
        on_press = () -> status_text[] = "Documentation link clicked")
    context = @rock E.Button("Show context menu"; on_press = () -> begin
        context_open[] = true
        status_text[] = "Context menu opened"
    end)
    dialog = @rock E.Button("Show message box"; on_press = () -> message_open[] = true)
    misc = @rock E.GroupBox(
        (@rock Row(tip, link, context, dialog; gap = 8, align = :center));
        title = "Menus and dialogs", caption_background = t.colors.window,
        fill = true)

    left = @rock E.Panel(@rock E.Label("Left pane"); background = t.colors.document,
                         border_color = t.colors.border, border_width = 1,
                         padding = 8, fill = true)
    right = @rock E.Panel(@rock E.Label("Right pane"); background = t.colors.document,
                          border_color = t.colors.border, border_width = 1,
                          padding = 8, fill = true)
    split = @rock E.SplitContainer(left, right; width = 1040, height = 170,
                                   ratio = 0.42)
    split_group = @rock E.GroupBox(split;
        title = "Split container", caption_background = t.colors.window,
        fill = true)

    menu_items = [E.MenuItem(label = "Cut", shortcut = "Ctrl+X"),
                  E.MenuItem(label = "Copy", shortcut = "Ctrl+C"),
                  E.MenuSeparator(),
                  E.MenuItem(label = "Properties")]
    ctx = @rock E.ContextMenu(open = context_open, x = 0, y = 0,
                              anchor_x = 60, anchor_y = 40,
                              items = menu_items,
                              position = :absolute, fill = true)
    page = @rock Column(buttons, misc, split_group; gap = 12, fill = fill)
    return @rock Box(page, ctx; direction = :column, fill = fill)
end

function App()
    t = theme[]
    status_obs = @use status_text
    status = status_obs[]
    menus = [
        E.Menu("File", items = [
            E.MenuItem(label = "New", shortcut = "Ctrl+N",
                       on_press = () -> status_text[] = "New document"),
            E.MenuItem(label = "Open...", shortcut = "Ctrl+O",
                       on_press = () -> status_text[] = "Open dialog"),
            E.MenuItem(label = "Save", shortcut = "Ctrl+S",
                       on_press = () -> status_text[] = "Saved"),
            E.MenuSeparator(),
            E.MenuItem(label = "Exit", on_press = quit!),
        ]),
        E.Menu("Edit", items = [
            E.MenuItem(label = "Undo", shortcut = "Ctrl+Z",
                       on_press = () -> status_text[] = "Undo"),
            E.MenuItem(label = "Redo", shortcut = "Ctrl+Y",
                       on_press = () -> status_text[] = "Redo"),
            E.MenuSeparator(),
            E.MenuItem(label = "Cut", shortcut = "Ctrl+X"),
            E.MenuItem(label = "Copy", shortcut = "Ctrl+C"),
            E.MenuItem(label = "Paste", shortcut = "Ctrl+V"),
        ]),
        E.Menu("View", items = [
            E.MenuItem(label = "Details", checked = true),
            E.MenuItem(label = "Large icons"),
            E.MenuItem(label = "Refresh", shortcut = "F5",
                       on_press = () -> status_text[] = "View refreshed"),
        ]),
        E.Menu("Help", items = [
            E.MenuItem(label = "About this app",
                       on_press = () -> message_open[] = true),
        ]),
    ]
    menu = @rock E.MenuBar(menus = menus)

    back = @rock E.ToolButton(icon = "arrow_back", tooltip = "Back")
    forward = @rock E.ToolButton(icon = "arrow_forward", tooltip = "Forward")
    up = @rock E.ToolButton(icon = "arrow_up", tooltip = "Up")
    open = @rock E.ToolButton(icon = "open", label = "Open")
    save = @rock E.ToolButton(icon = "save", label = "Save")
    refresh = @rock E.ToolButton(icon = "refresh", label = "Refresh",
                                 on_press = () -> status_text[] = "Refreshed")
    help = @rock E.ToolButton(icon = "help", label = "Help")
    toolbar = @rock E.ToolBar(back, forward, up,
        (@rock E.ToolSeparator()),
        open, save, refresh,
        (@rock E.ToolSeparator()),
        help)

    pages = [(@rock GeneralPage(fill = true)), (@rock FilesPage(fill = true)),
             (@rock ControlsPage(fill = true))]
    tabs = @rock E.TabControl(tabs = ["General", "Files", "Controls"],
                              selected = tab, children = pages, fill = true)

    statusbar = @rock E.StatusBar(panels = [
        E.StatusPanel(text = status, width = 420),
        E.StatusPanel(text = "3 objects", width = 110),
        E.StatusPanel(text = "Local disk (C:)", width = 150),
    ])

    dialog = @rock E.MessageBox(open = message_open, title = "About this app",
        message = "Rocks.Enterprise\nWindows 7 / Winforms component showcase.\n\nAll controls are native Rocks elements.",
        icon = :info, buttons = :okcancel, result = message_result,
        on_result = r -> status_text[] = "Message box: $r")

    return @rock E.ThemeContext.provider(
        @rock E.Form(
            tabs;
            menu = menu,
            toolbar = toolbar,
            status = statusbar,
            overlay = dialog,
            title = "Rocks.Enterprise — System Utility",
            width = 1100, height = 760,
            padding = 12,
            on_scroll = off -> status_text[] = "Scrolled to $(round(Int, off)) px");
        value = theme)
end

if abspath(PROGRAM_FILE) == @__FILE__
    haskey(ENV, "ROCKS_TAB") && (tab[] = parse(Int, ENV["ROCKS_TAB"]))
    if haskey(ENV, "ROCKS_SCREENSHOT")
        render(App; frames = 1, screenshot = ENV["ROCKS_SCREENSHOT"])
    else
        render(App)
    end
end
