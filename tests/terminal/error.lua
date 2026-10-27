-- Fails after taking the terminal, for tests-terminal: the client reports
-- the error and keeps the terminal, with no module to take keys, until ^C.

snowcone.start_ui()
ncurses.mvaddstr(0, 0, 'hello')
ncurses.refresh()
error 'boom'
