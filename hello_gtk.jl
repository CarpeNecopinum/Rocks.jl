using Gtk4

btn = GtkButton("Click me!")
win = GtkWindow("Hello GTK")
win[] = btn

show(win)