# Windows 7 / Winforms showcase for Rocks.Enterprise.
#
#   julia --project examples/enterprise.jl
#   SDL_VIDEO_DRIVER=dummy julia --project examples/enterprise.jl  # headless
#
# The app is a mock system utility: menu bar, toolbar, tabbed pages with group
# boxes and sunken inputs, list/grid views, progress and slider controls, a
# status bar, a modal message box and a context menu.
#
# The pages are laid out with the flexbox model: the boxes of a page stretch
# across the width of the page (`align = :stretch`), the controls that should
# keep their designed size carry an upper bound (`max_width`), and the
# elements that may grow say so with `flex`.

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

# A label with its control, the way a form is written.
function Labeled(; label, control)
    @rock Row(
        @rock Box(@rock E.Label(label); width = 130),
        control;
        gap = 8, align = :center)
end

function GeneralPage(; fill = false)
    @rock Column(
        @rock E.GroupBox(
            @rock Labeled(; label = "Name:",
                          control = @rock E.TextBox(text = name, width = 240,
                                                   flex_shrink = 1)),
            @rock Labeled(; label = "Organization:",
                          control = @rock E.TextBox(text = organization, width = 240,
                                                   flex_shrink = 1)),
            @rock Labeled(; label = "Department:",
                          control = @rock E.ComboBox(items = DEPARTMENTS,
                                                    selected = department,
                                                    width = 240,
                                                    flex_shrink = 1));
            title = "System"),

        @rock E.GroupBox(
            @rock E.CheckBox(checked = check_splash,
                             label = "Show splash screen at startup"),
            @rock E.CheckBox(checked = check_updates,
                             label = "Check for updates automatically"),
            @rock E.CheckBox(checked = check_telemetry,
                             label = "Send anonymous usage statistics");
            title = "Settings"),

        @rock E.GroupBox(
            @rock Row(
                @rock E.RadioButton(selected = radio_scale, value = 1,
                                   label = "Small (100%)"),
                @rock E.RadioButton(selected = radio_scale, value = 2,
                                   label = "Medium (125%)"),
                @rock E.RadioButton(selected = radio_scale, value = 3,
                                   label = "Large (150%)");
                gap = 16, align = :center);
            title = "Display scaling"),

        @rock E.GroupBox(
            @rock E.Label("Background task progress"),
            # The bar and the slider keep the width they were designed for.
            @rock E.ProgressBar(value = progress, width = 420, max_width = 420),
            @rock E.Label("Volume"),
            @rock E.Slider(value = volume, width = 420, ticks = 10,
                           max_width = 420);
            title = "Status"),

        @rock E.GroupBox(
            @rock E.ListView(items = RECENT_ITEMS, selected = recent_selected,
                             icons = true, width = 1040, height = 170,
                             max_width = 1040, max_height = 170);
            title = "Recent items"),

        @rock E.GroupBox(
            @rock E.Label("Last check: today at 09:42"),
            @rock E.Label("Version: 7.4.1 (build 2026.10)"),
            @rock E.Label("No maintenance tasks are currently scheduled.");
            title = "Maintenance"),

        # Reserve transparent space below the combo box so its popup is not
        # covered by later siblings. `pointer_events = :none` keeps the popup
        # hittable.
        @rock Box(; height = 90, pointer_events = :none),

        @rock Row(
            @rock E.Button("Apply";
                           on_press = () -> status_text[] = "Settings applied",
                           max_width = 120),
            @rock E.Button("Cancel", max_width = 120),
            @rock E.Button("OK"; default = true,
                           on_press = () -> status_text[] = "Changes accepted",
                           max_width = 120);
            gap = 6, align = :center, justify = :end);
        # The page is as wide as the viewport and its boxes stretch with it.
        gap = 12, fill = fill, align = :stretch)
end

function FilesPage(; fill = false)
    @rock Column(
        @rock E.GroupBox(
            @rock Row(
                @rock E.ListView(items = FILE_ITEMS, selected = list_selected,
                                 icons = true, width = 440, height = 300,
                                 max_width = 440, max_height = 300,
                                 flex_shrink = 1),
                @rock E.GridView(columns = GRID_COLUMNS, rows = GRID_ROWS,
                                 selected = grid_selected, width = 585,
                                 height = 300, max_width = 585, max_height = 300,
                                 flex_shrink = 1, fill = true);
                gap = 12, align = :start);
            title = "Files and folders"),

        @rock Row(
            @rock E.Button("Refresh"; icon = "refresh",
                           on_press = () -> status_text[] = "File list refreshed",
                           max_width = 140),
            @rock E.Button("Details", max_width = 140);
            gap = 6, align = :center);
        gap = 12, fill = fill, align = :stretch)
end

function ControlsPage(; fill = false)
    @rock Column(
        @rock E.GroupBox(
            @rock Row(
                @rock E.Button("Normal", max_width = 120),
                @rock E.Button("Default"; default = true, max_width = 120),
                @rock E.Button("Disabled"; disabled = true, max_width = 120),
                @rock E.Button("Open"; icon = "open", max_width = 120);
                gap = 6, align = :center);
            title = "Buttons"),

        @rock E.GroupBox(
            @rock Row(
                @rock E.ToolTip(@rock E.Button("Hover for tooltip");
                                text = "A classic Win7 tooltip"),
                @rock E.LinkLabel("Open documentation";
                    on_press = () -> status_text[] = "Documentation link clicked"),
                @rock E.Button("Show context menu"; on_press = () -> begin
                    context_open[] = true
                    status_text[] = "Context menu opened"
                end, max_width = 180),
                @rock E.Button("Show message box";
                               on_press = () -> message_open[] = true,
                               max_width = 180);
                gap = 8, align = :center);
            title = "Menus and dialogs"),

        @rock E.GroupBox(
            @rock E.SplitContainer(
                @rock E.Panel(@rock E.Label("Left pane");
                              background = E.light_theme().colors.document,
                              border_color = E.light_theme().colors.border,
                              border_width = 1, padding = 8, fill = true),
                @rock E.Panel(@rock E.Label("Right pane");
                              background = E.light_theme().colors.document,
                              border_color = E.light_theme().colors.border,
                              border_width = 1, padding = 8, fill = true);
                width = 1040, height = 170, max_width = 1040, max_height = 170,
                ratio = 0.42);
            title = "Split container");

        @rock E.ContextMenu(open = context_open, x = 60, y = 50,
            items = [E.MenuItem(label = "Cut", shortcut = "Ctrl+X"),
                     E.MenuItem(label = "Copy", shortcut = "Ctrl+C"),
                     E.MenuSeparator(),
                     E.MenuItem(label = "Properties")]);
        gap = 12, fill = fill, align = :stretch)
end

function App()
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

    # The menu, the toolbar, the status bar and the dialog are passed to the
    # form as props, so they stay in variables (a `@rock` element cannot be
    # inlined into a prop value).
    menu = @rock E.MenuBar(menus = menus)
    toolbar = @rock E.ToolBar(
        @rock E.ToolButton(icon = "arrow_back", tooltip = "Back"),
        @rock E.ToolButton(icon = "arrow_forward", tooltip = "Forward"),
        @rock E.ToolButton(icon = "arrow_up", tooltip = "Up"),
        @rock E.ToolSeparator(),
        @rock E.ToolButton(icon = "open", label = "Open"),
        @rock E.ToolButton(icon = "save", label = "Save"),
        @rock E.ToolButton(icon = "refresh", label = "Refresh",
                           on_press = () -> status_text[] = "Refreshed"),
        @rock E.ToolSeparator(),
        @rock E.ToolButton(icon = "help", label = "Help"))
    statusbar = @rock E.StatusBar(panels = [
        E.StatusPanel(text = status, width = 420),
        E.StatusPanel(text = "3 objects", width = 110),
        E.StatusPanel(text = "Local disk (C:)", width = 150),
    ])
    dialog = @rock E.MessageBox(open = message_open,
        title = "About this app",
        message = "Rocks.Enterprise\nWindows 7 / Winforms component showcase.\n\nAll controls are native Rocks elements.",
        icon = :info, buttons = :okcancel, result = message_result,
        on_result = r -> status_text[] = "Message box: $r")

    @rock E.ThemeContext.provider(
        @rock E.Form(
            @rock E.TabControl(tabs = ["General", "Files", "Controls"],
                                selected = tab,
                                children = [@rock GeneralPage(fill = true),
                                            @rock FilesPage(fill = true),
                                            @rock ControlsPage(fill = true)],
                                fill = true);
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
