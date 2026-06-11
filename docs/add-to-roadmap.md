---
id: add-to-roadmap
aliases: []
tags: []
---

# Add-to-roadmap

These are things that are not in the roadmap right now, but I want them to be.

1. Easily connect to a specific database: Part of what is awesome about Marimo is that I can create a database with python, and then select it when in a sql cell in Marimo, and then just run straight sql queries with no issue. Right now, I can't do that. This is an important part of feature parity to me.
2. Improvements to the widgets - my recent Fable run with its new phase 9 just imporved the widgets, but there are ux improvements I want to make
   1. easier to edit a single widget: when there is one widget in a cell, you should not have to see the menu pop up with that widget listed, you should just instantly be able to change a widget
   2. editing multiple widgets: if there is more then one widget in a cell, the menu should pop up, but you should be able to select what widget you want based on its order. for example, if there are three widgets, they should be in the menu in the order that they appear, and i should be able to select a widget by just typing the number it appears in. so for the three widget example, i can press <leader>mw, and then 2, and that should allow me to edit the second widget.
   3. Tabs: when using marimo tabs that can hold different elements like widgets, when i press <leader>mw it should show the menu it normally does, but I should be able to press `tab` and I can cycle through the widgets in different tabs, then press a number to select that numbered widget within that tab. So the menu looks the same, it just has a new part to indicate I can press `tab` to cycle through the list of tabs, and then press the number that I want from within that tab. I also want the output to more clearly indicate that different widgets are in different tabs, right now it is hard to see visually which widgets are in which tab
   4. Easier UX for widgets: right now, the only way to change a widget is to go to that cell, do <leader>mw, select the widget you want, and then you can change it. But what if you want to edit the same widget multiple times in a row to see a value change? This would be a lot of manual work each time in the current implementation. i would like a way to easily go back and edit the last edited widget. Additionally it would be really nice if there was some feature to be able to "pin" certain widgets, and then be able to open them together. this way, one easy keyboard shortcut can get someone to access the important widgets, even if those widgets are in different cells. This could be used to edit more frequent widgets across the notebook, and then you can edit all the widgets within one cell like you could before.
