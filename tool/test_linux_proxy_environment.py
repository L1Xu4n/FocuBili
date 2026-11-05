"""Check the GIO resolver primitives used by Linux environment fallback.

Runs without development headers, against the real installed GIO library.
This is not a complete Flutter channel integration test.
"""
import ctypes as c
import unittest


class EnvironmentResolverTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.gio = c.CDLL('libgio-2.0.so.0')
        cls.glib = c.CDLL('libglib-2.0.so.0')
        cls.obj = c.CDLL('libgobject-2.0.so.0')
        cls.gio.g_simple_proxy_resolver_new.argtypes = [c.c_char_p, c.POINTER(c.c_char_p)]
        cls.gio.g_simple_proxy_resolver_new.restype = c.c_void_p
        cls.gio.g_simple_proxy_resolver_set_uri_proxy.argtypes = [c.c_void_p, c.c_char_p, c.c_char_p]
        cls.gio.g_proxy_resolver_lookup.argtypes = [c.c_void_p, c.c_char_p, c.c_void_p, c.POINTER(c.c_void_p)]
        cls.gio.g_proxy_resolver_lookup.restype = c.POINTER(c.c_char_p)
        cls.glib.g_strfreev.argtypes = [c.POINTER(c.c_char_p)]
        cls.obj.g_object_unref.argtypes = [c.c_void_p]

    def resolve(self, url, http=None, https=None, ignored=(), all_proxy=None):
        if http is None:
            http = all_proxy
        if https is None:
            https = all_proxy
        ignore = (c.c_char_p * (len(ignored) + 1))(*ignored, None)
        resolver = self.gio.g_simple_proxy_resolver_new(None, ignore)
        try:
            # The native bridge special-cases '*' because GSimpleProxyResolver
            # does not implement that environment-variable convention itself.
            ignore_all = b'*' in ignored
            for scheme, proxy in [(b'http', http), (b'https', https)]:
                route = proxy if not ignore_all and proxy else b'direct://'
                self.gio.g_simple_proxy_resolver_set_uri_proxy(resolver, scheme, route)
            error = c.c_void_p()
            routes = self.gio.g_proxy_resolver_lookup(resolver, url, None, c.byref(error))
            self.assertFalse(error.value)
            self.assertTrue(routes)
            result = routes[0]
            self.glib.g_strfreev(routes)
            return result
        finally:
            self.obj.g_object_unref(resolver)

    def test_scheme_specific_proxies(self):
        self.assertEqual(self.resolve(b'https://api.example.com/',
            http=b'http://one:80', https=b'http://two:81'), b'http://two:81')
        self.assertEqual(self.resolve(b'http://api.example.com/',
            http=b'http://one:80', https=b'http://two:81'), b'http://one:80')

    def test_unconfigured_scheme_is_direct(self):
        self.assertEqual(self.resolve(b'https://api.example.com/',
            http=b'http://one:80'), b'direct://')

    def test_all_proxy_default_and_explicit_empty_override(self):
        self.assertEqual(self.resolve(b'https://api.example.com/',
            all_proxy=b'http://default:80'), b'http://default:80')
        self.assertEqual(self.resolve(b'https://api.example.com/',
            https=b'', all_proxy=b'http://default:80'), b'direct://')

    def test_no_proxy_domain(self):
        self.assertEqual(self.resolve(b'https://api.example.com/',
            https=b'http://one:80', ignored=(b'.example.com',)), b'direct://')
        self.assertEqual(self.resolve(b'https://notexample.com/',
            https=b'http://one:80', ignored=(b'.example.com',)), b'http://one:80')

    def test_no_proxy_ip_range(self):
        self.assertEqual(self.resolve(b'https://127.0.0.1/',
            https=b'http://one:80', ignored=(b'127.0.0.0/8',)), b'direct://')

    def test_no_proxy_all(self):
        self.assertEqual(self.resolve(b'https://api.example.com/',
            https=b'http://one:80', ignored=(b'*',)), b'direct://')


if __name__ == '__main__':
    unittest.main()
