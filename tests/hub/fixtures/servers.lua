-- A synthetic servers file for tests/hub/test-topology.lua
{
    primary_hub = 'hub.example',
    servers = {
        ['alpha.example'] = {alias = 'al', region = 'EU', ipv4 = '127.0.0.1'},
        ['beta.example'] = {alias = 'be', region = 'US'},
        ['hub.example'] = {alias = 'hb'},
    },
    regions = {
        MAIN = {hostname = 'localhost'},
        EU = {color = 'green'},
    },
    kline_reasons = {
        {'spam', 'Spamming is not allowed'},
        {'abuse', 'Abuse|ticket'},
    },
    kline_tags = {'tagged'},
    net_tracks = {
        docs = {'192.0.2.0/24', '2001:db8::/32'},
    },
}
