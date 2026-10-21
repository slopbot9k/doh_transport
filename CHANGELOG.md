## 0.0.1

- First release.
- Bounded RFC 8484 wire POST and GET exchanges over HTTPS, direct, to a fixed
  destination address, or through SOCKS5 with Tor stream isolation.
- Connection reuse for wire queries, bounded bodies and deadlines, and a sealed
  exception hierarchy; only HTTP 200 bodies are delivered.
