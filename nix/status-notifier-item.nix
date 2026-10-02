# status-notifier-item 0.3.2.16 pinned from Hackage (nixpkgs has
# 0.3.1.0; the ItemInfo tooltip fields homgb uses need the newer one).
self: super: {
  status-notifier-item = self.callHackageDirect {
    pkg = "status-notifier-item";
    ver = "0.3.2.16";
    sha256 = "012qdwx0j5aj2173d2f6k4ygvm0q70zbsa1xg4v8fb1pawcxwm7h";
  } { };
}
