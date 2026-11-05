#!/usr/bin/env python3
"""Portable Windows proxy-parser regressions (requires g++).

Extracts the actual production parser. WinHTTP/Flutter are not exercised here.
PathMatchSpecW is replaced by fnmatch for the simple wildcard fixtures below;
Windows CI must still build the runner and validate real OS/PAC integration.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "windows/runner/network_proxy.cpp").read_text()
parser = (source[source.index("std::wstring Lower"):source.index("struct IeConfig")]
          + source[source.index("std::string Route"):source.index("std::string Resolve")])
PREAMBLE = r'''
#include <string>
#include <vector>
#include <algorithm>
#include <cwctype>
#include <stdexcept>
#include <cassert>
#include <fnmatch.h>
#include <iostream>
using INTERNET_PORT = unsigned short;
std::string Utf8(const std::wstring& s) { return std::string(s.begin(), s.end()); }
bool PathMatchSpecW(const wchar_t* s, const wchar_t* p) { return fnmatch(Utf8(p).c_str(), Utf8(s).c_str(), 0) == 0; }
'''
TESTS = r'''
int main() {
assert(Route(nullptr, nullptr, L"https", L"api.bilibili.com", 443) == "DIRECT");
assert(Route(L"127.0.0.1:7890", nullptr, L"https", L"api.bilibili.com", 443) == "PROXY 127.0.0.1:7890");
assert(Route(L"http=one:80;https=two:81", nullptr, L"https", L"host", 443) == "PROXY two:81");
assert(Route(L"http=one:80", nullptr, L"https", L"host", 443) == "DIRECT");
assert(Route(L"proxy:8080", L"*.bilibili.com;<local>", L"https", L"api.bilibili.com", 443) == "DIRECT");
assert(Route(L"proxy:8080", L"<local>", L"http", L"localhost", 80) == "DIRECT");
assert(Route(L"proxy:8080", L"<local>", L"https", L"api.bilibili.com", 443) == "PROXY proxy:8080");
assert(Route(L"[::1]:7890", nullptr, L"https", L"host", 443) == "PROXY [::1]:7890");
assert(Route(L"http://proxy", nullptr, L"https", L"host", 443) == "PROXY proxy:80");
// Select only the first applicable candidate, without validating fallbacks.
assert(Route(L"one:80;socks://later:1080", nullptr, L"https", L"host", 443) == "PROXY one:80");
assert(Route(L"one:80;later:0", nullptr, L"https", L"host", 443) == "PROXY one:80");
assert(Route(L"https=one:80;https=", nullptr, L"https", L"host", 443) == "PROXY one:80");
assert(Route(L"https=one:80;unknown=;SOCKS=", nullptr, L"https", L"host", 443) == "PROXY one:80");
assert(Route(L"one:80;http=;unknown=", nullptr, L"https", L"host", 443) == "PROXY one:80");
// Scheme-specific routes still take precedence over generic routes, regardless
// of their position; unrelated malformed mappings do not change selection.
assert(Route(L"socks://generic:1080;https=selected:81", nullptr, L"https", L"host", 443) == "PROXY selected:81");
assert(Route(L"http=;https=selected:81", nullptr, L"https", L"host", 443) == "PROXY selected:81");
for (const auto* proxy : {L"user:pass@proxy:80", L"socks://proxy:1080", L"SOCKS=proxy:1080", L"proxy:0", L"proxy:65536", L"proxy:x", L"::1:8080", L"SOCKS5=proxy:1080", L"unknown=proxy:8080", L"https=", L"proxy#evil:80", L"proxy?evil:80", L"proxy\\evil:80", L"socks://first:1080;valid:80", L"first:0;valid:80", L"https=;https=valid:80", L"generic:80;https=socks://selected:1080"}) {
  bool rejected = false;
  try { Route(proxy, nullptr, L"https", L"host", 443); } catch (...) { rejected = true; }
  assert(rejected);
}
std::cout << "33 static proxy parser checks passed\n";
}
'''
with tempfile.TemporaryDirectory(prefix="focubili-proxy-test-") as directory:
    cpp = Path(directory) / "proxy_test.cpp"
    binary = Path(directory) / "proxy_test"
    cpp.write_text(PREAMBLE + parser + TESTS)
    subprocess.run(["g++", "-std=c++17", "-Wall", "-Wextra", "-Werror",
                    str(cpp), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
