-- Given "n!u@h" returns "n", "u", "h"
return function(str)
    return str:match '^([^!]*)!([^@]*)@(.*)$'
end
