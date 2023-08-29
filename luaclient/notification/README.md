# Notification modules

Modules are expected to provide two functions:

```lua
function notify(previous_tag, target, nick, message)
function dismiss(tag)
```

The `notify` function should return a tag to pass to dismiss when the
window gets focus later. This can optionally be used to remove a
notification from the notification system.

When notify is called it gets `nil` or the previous tag value. This
can be used to avoid repeated notifications to to group them together.

Dismiss is called when the affected buffer is rendered to screen and
the terminal has focus.
