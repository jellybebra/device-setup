"""Generate explicit zapret2 candidates; no broad automatic host list."""
import argparse
from pathlib import Path

GOOGLE = ['youtube.com','youtu.be','googlevideo.com','ytimg.com','ggpht.com','youtubei.googleapis.com','youtube.googleapis.com','yt3.googleusercontent.com']
SOCIAL = ['discord.com','discord.gg','discordapp.com','discordapp.net','discord.media','discordcdn.com','discordstatus.com','discord.gift','discord.new','instagram.com','cdninstagram.com','ig.me','fbcdn.net','facebook.com','fbsbx.com','x.com','twitter.com','t.co','twimg.com','pscp.tv','periscope.tv']


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    a.output.mkdir(parents=True, exist_ok=True)
    for name, values in [('google',GOOGLE),('social',SOCIAL),('web',GOOGLE+SOCIAL)]:
        (a.output / f'{name}.txt').write_text('\n'.join(values)+'\n', newline='\n')
    base = '/opt/zapret2'
    ip_exclusions = f'--ipset-exclude={base}/ipset/vpn-endpoints.txt'
    exclusions = f'{ip_exclusions} --hostlist-exclude={base}/ipset/exclude-hosts.txt'
    for mode in ['alt9','alt11','exp']:
        blobs = ' '.join(f'--blob={name}:@{base}/files/{file}' for name,file in {
            'flow_quic':'quic_initial_www_google_com.bin','flow_google':'tls_clienthello_www_google_com.bin',
            'flow_sferum':'tls_clienthello_www_sferum_ru.bin','flow_stun':'stun2.bin','flow_discord':'ACTIVE_DISCORD_UDP.bin',
        }.items())
        def tcp(google=False, cloudflare=False):
            if mode == 'alt9' or (mode == 'exp' and google):
                host = 'www.google.com' if google else 'ozon.ru'
                md5 = ':tcp_md5' if not google and not cloudflare else ''
                return f'--lua-desync=hostfakesplit:host={host}:repeats=4:tcp_ts=-600000{md5}'
            blob = 'flow_google' if google else 'flow_sferum'
            repeat = 8 if mode == 'alt11' else 4
            overlap = 681 if google else (664 if mode == 'alt11' else 480)
            fake = '' if google else f'--lua-desync=fake:blob=flow_stun:repeats={repeat}:tcp_ts=-600000 '
            return fake + f'--lua-desync=fake:blob={blob}:repeats={repeat}:tcp_ts=-600000 --lua-desync=multisplit:pos=1:seqovl={overlap}:seqovl_pattern={blob}'
        quic = f'--payload=quic_initial --lua-desync=fake:blob=flow_quic:repeats={11 if mode == "alt11" else 6}'
        profiles = [
            f'--filter-tcp=443 --hostlist-domains=trycloudflare.com {exclusions} --payload=tls_client_hello --lua-desync=fake:blob=flow_google:repeats=12:tcp_ts=-600000',
            f'--filter-tcp=7844 --ipset={base}/ipset/cloudflare.txt {exclusions} --payload=tls_client_hello --lua-desync=fake:blob=flow_google:repeats=12:tcp_ts=-600000',
            f'--filter-udp=7844 --filter-l7=quic --ipset={base}/ipset/cloudflare.txt {exclusions} --payload=quic_initial --lua-desync=fake:blob=flow_quic:repeats=6',
            f'--filter-tcp=80,443 --hostlist-domains=x.com {exclusions} --payload=tls_client_hello --lua-desync=fake:blob=flow_google:repeats=12:tcp_ts=-600000',
            f'--filter-tcp=443,8443 --ipset={base}/ipset/cloudflare.txt {exclusions} --payload=tls_client_hello --lua-desync=fake:blob=flow_google:repeats=12:tcp_ts=-600000',
            # Discord discovery/STUN have no hostname. Even a hostlist exclusion
            # prevents nfqws2 from selecting this profile for those packets.
            f'--filter-udp=19294-19344,50000-50100 --filter-l7=discord,stun {ip_exclusions} --payload=discord_ip_discovery,stun --lua-desync=fake:blob=flow_quic:repeats=6',
            f'--filter-udp=443 --filter-l7=quic --hostlist={base}/ipset/web.txt {exclusions} {quic}',
            f'--filter-udp=443 --filter-l7=quic --ipset={base}/ipset/cloudflare.txt {exclusions} {quic}',
            f'--filter-tcp=443 --hostlist={base}/ipset/google.txt {exclusions} --payload=tls_client_hello {tcp(True)}',
            f'--filter-tcp=2053,2083,2087,2096,8443 --hostlist-domains=discord.media {exclusions} --payload=tls_client_hello --lua-desync=fake:blob=flow_google:repeats=12:tcp_ts=-600000',
            f'--filter-tcp=80,443 --hostlist={base}/ipset/social.txt {exclusions} --payload=tls_client_hello,http_req {tcp()}',
            f'--filter-tcp=80,443,8443 --ipset={base}/ipset/cloudflare.txt {exclusions} --payload=tls_client_hello,http_req {tcp(cloudflare=True)}',
        ]
        config = '\n'.join([
            'FWTYPE=nftables', 'NFQWS2_ENABLE=1', 'MODE_FILTER=none', 'FLOWOFFLOAD=none',
            'DISABLE_IPV6=1','INIT_APPLY_FW=1','POSTNAT=1','OPENWRT_WAN4=wan',
            'INIT_FW_PRE_UP_HOOK=/opt/zapret2/refresh-endpoint.sh',
            'INIT_FW_POST_UP_HOOK=/opt/zapret2/zapret-guard.sh',
            'DESYNC_MARK=0x40000000','DESYNC_MARK_POSTNAT=0x20000000',
            'NFQWS2_PORTS_TCP=80,443,2053,2083,2087,2096,7844,8443',
            'NFQWS2_PORTS_UDP=443,7844,19294-19344,50000-50100',
            'NFQWS2_TCP_PKT_OUT=20','NFQWS2_TCP_PKT_IN=10',
            'NFQWS2_UDP_PKT_OUT=5','NFQWS2_UDP_PKT_IN=3',
            'FILTER_TTL_EXPIRED_ICMP=1', 'SET_MAXELEM=16384',
            f'NFQWS2_OPT="{blobs}\n' + ' --new\n'.join(profiles) + '\n"',
        ])+'\n'
        (a.output / f'config.{mode}').write_text(config, newline='\n')
    print('Generated three candidates and domain lists.')


if __name__ == '__main__':
    main()
