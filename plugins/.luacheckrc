-- Plugins run in the client's global environment and see its native modules
return {
std = "lua54+snowcone",
stds = {
    snowcone = {
        read_globals = {"snowcone", "ncurses", "myopenssl", "mybase64", "mytoml", "mystringprep"},
    },
},
}
