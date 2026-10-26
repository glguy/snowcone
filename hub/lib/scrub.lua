local repls = {
    ['\x00'] = '␀', ['\x01'] = '␁', ['\x02'] = '␂', ['\x03'] = '␃',
    ['\x04'] = '␄', ['\x05'] = '␅', ['\x06'] = '␆', ['\x07'] = '␇',
    ['\x08'] = '␈', ['\x09'] = '␉', ['\x0a'] = '␤', ['\x0b'] = '␋',
    ['\x0c'] = '␌', ['\x0d'] = '␍', ['\x0e'] = '␎', ['\x0f'] = '␏',
    ['\x10'] = '␐', ['\x11'] = '␑', ['\x12'] = '␒', ['\x13'] = '␓',
    ['\x14'] = '␔', ['\x15'] = '␕', ['\x16'] = '␖', ['\x17'] = '␗',
    ['\x18'] = '␘', ['\x19'] = '␙', ['\x1a'] = '␚', ['\x1b'] = '␛',
    ['\x1c'] = '␜', ['\x1d'] = '␝', ['\x1e'] = '␞', ['\x1f'] = '␟',
    ['\x7f'] = '␡',
}

return function(str)
    str = string.gsub(str, '[\x00-\x1f\x7f]', repls)
    -- C1 controls (U+0080 to U+009F), which some terminals obey: U+009C
    -- ends an OSC sequence, for one. Rare, so checked for first.
    if string.find(str, '\xc2', 1, true) then
        str = string.gsub(str, '\xc2[\x80-\x9f]', '\u{fffd}')
    end
    return str
end
