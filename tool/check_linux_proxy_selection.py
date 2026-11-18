#!/usr/bin/env python3
"""Run the actual Linux proxy-result callback against ordered proxy fixtures.

Requires g++ and the GIO runtime, not Flutter or GLib development headers.
Only the Flutter reply and async lookup completion are mocked. URI parsing and
string operations use the real GIO/GLib libraries; OS discovery is not exercised.
"""
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "linux/runner/my_application.cc").read_text()
callback = source[source.index("static void proxy_lookup_finished("):
                  source.index("// An explicitly set lowercase variable")]

PREAMBLE = r'''
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>

using gsize = size_t;
using guint16 = uint16_t;
using gpointer = void*;
using GObject = void;
using GAsyncResult = void;
using GSocketConnectable = void;
using GError = void;
using GStrv = char**;
struct GString { char* str; gsize len; gsize allocated_len; };
extern "C" {
int g_strcmp0(const char*, const char*);
int g_str_has_prefix(const char*, const char*);
GString* g_string_new(const char*);
GString* g_string_append(GString*, const char*);
void g_string_append_printf(GString*, const char*, ...);
char* g_string_free(GString*, int);
GSocketConnectable* g_network_address_parse_uri(const char*, guint16, GError**);
const char* g_network_address_get_hostname(void*);
guint16 g_network_address_get_port(void*);
void g_object_unref(void*);
void g_error_free(GError*);
}

struct FlValue { std::string value; };
struct FlMethodCall { std::string value; std::string error; };
static char** fixture;
static std::vector<GString*> strings;
static std::vector<GSocketConnectable*> addresses;
static std::vector<GError*> errors;
static std::vector<FlValue*> values;
static GString* tracked_string_new(const char* value) {
  auto* result = g_string_new(value); strings.push_back(result); return result;
}
static GSocketConnectable* tracked_parse_uri(const char* uri, guint16 port, GError** error) {
  auto* result = g_network_address_parse_uri(uri, port, error);
  if (result) addresses.push_back(result);
  if (*error) errors.push_back(*error);
  return result;
}
static char** g_proxy_resolver_lookup_finish(void*, void*, GError**) { return fixture; }
static FlValue* fl_value_new_string(const char* value) {
  auto* result = new FlValue{value}; values.push_back(result); return result;
}
static void fl_method_call_respond_success(FlMethodCall* call, FlValue* value, void*) {
  call->value = value->value;
}
static void fl_method_call_respond_error(FlMethodCall* call, const char* code,
                                        const char*, void*, void*) {
  call->error = code;
}
// Lifetime is cleaned after every fixture instead of GLib's cleanup attribute.
#define g_autoptr(Type) Type*
#define g_auto(Type) Type
#define FL_METHOD_CALL(value) static_cast<FlMethodCall*>(value)
#define G_PROXY_RESOLVER(value) (value)
#define G_IS_NETWORK_ADDRESS(value) ((value) != nullptr)
#define G_NETWORK_ADDRESS(value) (value)
#define g_string_new tracked_string_new
#define g_network_address_parse_uri tracked_parse_uri
'''

TESTS = r'''
static void check(std::initializer_list<const char*> routes,
                  const char* expected, const char* error = "") {
  std::vector<char*> input;
  for (const auto* route : routes) input.push_back(const_cast<char*>(route));
  input.push_back(nullptr);
  fixture = input.data();
  FlMethodCall call;
  proxy_lookup_finished(nullptr, nullptr, &call);
  assert(call.value == expected);
  assert(call.error == error);
  for (auto* value : strings) g_string_free(value, true);
  for (auto* value : addresses) g_object_unref(value);
  for (auto* value : errors) g_error_free(value);
  for (auto* value : values) delete value;
  strings.clear(); addresses.clear(); errors.clear(); values.clear();
}
int main() {
  check({"http://proxy.test:8080", "socks5://fallback.test:1080"}, "PROXY proxy.test:8080");
  check({"direct://", "socks5://fallback.test:1080"}, "DIRECT");
  check({"http://proxy.test:8080", "http://user:password@fallback.test:80"}, "PROXY proxy.test:8080");
  check({"direct://", "not-a-proxy"}, "DIRECT");
  check({"http://proxy.test:8080", "http://fallback.test:bad"}, "PROXY proxy.test:8080");
  check({"http://first.test:80", "http://second.test:81"}, "PROXY first.test:80");
  check({"http://[::1]:8080", "socks5://fallback.test:1080"}, "PROXY [::1]:8080");
  check({"socks5://first.test:1080", "http://valid.test:80"}, "", "unsupported_proxy");
  check({"http://user:password@first.test:80", "direct://"}, "", "unsupported_proxy");
  check({"http://first.test:bad", "http://valid.test:80"}, "", "invalid_proxy");
  check({"not-a-proxy", "direct://"}, "", "unsupported_proxy");
  check({}, "", "proxy_resolution_failed");
  std::cout << "12 Linux selected-proxy callback checks passed\n";
}
'''

with tempfile.TemporaryDirectory(prefix="focubili-linux-proxy-test-") as directory:
    cpp = Path(directory) / "proxy_test.cpp"
    binary = Path(directory) / "proxy_test"
    cpp.write_text(PREAMBLE + callback + TESTS)
    subprocess.run(["g++", "-std=c++17", "-Wall", "-Wextra", "-Werror",
                    str(cpp), "-Wl,-l:libgio-2.0.so.0",
                    "-Wl,-l:libglib-2.0.so.0", "-Wl,-l:libgobject-2.0.so.0",
                    "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
