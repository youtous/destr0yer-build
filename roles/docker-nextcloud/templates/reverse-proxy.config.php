<?php
# todo : remove when PR is merged
putenv("OVERWRITEHOST={{ nextcloud_domain }}");
putenv("OVERWRITEPROTOCOL=https");
putenv("TRUSTED_PROXIES=172.28.0.0/16 10.0.0.0/8");
# from https://github.com/andrasmaroy/nextcloud-docker/blob/master/18.0/fpm/config/reverse-proxy.config.php
$overwriteHost = getenv('OVERWRITEHOST');
if ($overwriteHost) {
  $CONFIG['overwritehost'] = $overwriteHost;
}

$overwriteProtocol = getenv('OVERWRITEPROTOCOL');
if ($overwriteProtocol) {
  $CONFIG['overwriteprotocol'] = $overwriteProtocol;
}

$overwriteWebRoot = getenv('OVERWRITEWEBROOT');
if ($overwriteWebRoot) {
  $CONFIG['overwritewebroot'] = $overwriteWebRoot;
}

$overwriteCondAddr = getenv('OVERWRITECONDADDR');
if ($overwriteCondAddr) {
  $CONFIG['overwritecondaddr'] = $overwriteCondAddr;
}

$trustedProxies = getenv('TRUSTED_PROXIES');
if ($trustedProxies) {
  $CONFIG['trusted_proxies'] = array_filter(array_map('trim', explode(' ', $trustedProxies)));
}