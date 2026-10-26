-- A synthetic servers file for the hub tests, using every key a real one
-- does (no real addresses: documentation ranges and .example names)
{
    primary_hub = 'hub.example',
    flags = {'+'},
    servers = {
        ['alpha.example'] = {alias = 'al', region = 'EU', ipv4 = '127.0.0.1', ipv6 = '2001:db8::1', expect = {'+'}},
        ['beta.example'] = {alias = 'be', region = 'US', ipv4 = '192.0.2.2', ipv6 = nil, expect = {'+'}},
        ['hub.example'] = {alias = 'hb', ipv4 = nil, ipv6 = nil, region = nil, expect = nil},
    },
    regions = {
        MAIN = {hostname = 'localhost'},
        EU = {hostname = 'eu.invalid', color = 'green'},
        US = {color = 'red'},
        ['+'] = {hostname = 'plus.invalid', color = 'cyan'},
    },
    kline_reasons = {
        {'spam', 'Spamming is not allowed'},
        {'abuse', 'Abuse|ticket'},
    },
    kline_tags = {'tagged'},
    net_tracks = {
        docs = {'192.0.2.0/24', '2001:db8::/32'},
        ['odd.prefix'] = {'2001:db8:f::/62', '198.51.100.56/29', '203.0.113.7'},
    },
}
