import 'dart:io';

// Main-frame navigation guard only. webview_flutter has no subresource
// interception, so this is not network isolation. A [vpn] tab's names are
// looked up in WSL, where the Relay backend's proxy applies the same rule;
// its address literals and localhost, which need no lookup, are checked here.
Future<Uri> browserUrl(String text, {bool vpn = false}) async {
  final value = text.trim();
  final uri = Uri.parse(
    value.contains('://')
        ? value
        : RegExp(
            r'^[\w.-]+\.[a-z]{2,}([/:?#]|$)',
            caseSensitive: false,
          ).hasMatch(value)
        ? 'https://$value'
        : 'https://www.google.com/search?q=${Uri.encodeQueryComponent(value)}',
  );
  if (!['https', 'http'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    throw Exception('Use a public HTTP or HTTPS website.');
  }
  // Browsers read a host that ends in a number as an IPv4 address, also in
  // spellings such as 127.1, 2130706433 or 0x7f000001; only plain dotted
  // decimal is accepted, so the rule below sees the address the browser uses.
  final host = uri.host.endsWith('.')
      ? uri.host.substring(0, uri.host.length - 1)
      : uri.host;
  if (RegExp(
        r'(^|\.)(\d+|0x[0-9a-f]*)$',
        caseSensitive: false,
      ).hasMatch(host) &&
      !RegExp(r'^(0|[1-9]\d{0,2})(\.(0|[1-9]\d{0,2})){3}$').hasMatch(host)) {
    throw Exception('Use a public HTTP or HTTPS website.');
  }
  if (vpn && InternetAddress.tryParse(host) == null && host != 'localhost') {
    return uri;
  }
  final addresses = await InternetAddress.lookup(uri.host);
  bool privateAddress(InternetAddress address) {
    final b = address.rawAddress;
    if (address.isLoopback || address.isLinkLocal || address.isMulticast) {
      return true;
    }
    if (address.type == InternetAddressType.IPv4) {
      return b[0] == 0 ||
          b[0] == 10 ||
          b[0] == 127 ||
          b[0] >= 224 ||
          (b[0] == 169 && b[1] == 254) ||
          (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
          (b[0] == 192 && b[1] == 168) ||
          (b[0] == 100 && b[1] >= 64 && b[1] <= 127);
    }
    return b.every((n) => n == 0) ||
        (b[0] & 0xfe) == 0xfc ||
        (b.take(10).every((n) => n == 0) && b[10] == 255 && b[11] == 255);
  }

  if (addresses.isEmpty || addresses.any(privateAddress)) {
    throw Exception('Public browser tabs cannot open private addresses.');
  }
  return uri;
}

/// Whether a Browser tab or popup may load [url] in its main frame.
Future<bool> publicPageAllowed(String url, {bool vpn = false}) async {
  if (url == 'about:blank') return true;
  if (!['https', 'http'].contains(Uri.tryParse(url)?.scheme)) return false;
  try {
    await browserUrl(url, vpn: vpn);
    return true;
  } catch (_) {
    return false;
  }
}
