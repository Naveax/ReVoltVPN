---

<p align="center">
  <img src="screenshots/feature_graphic.png" alt="ReVoltVPN banner" width="100%"/>
</p>

# ReVoltVPN
A free VPN app I built in my spare time as a student with basically no prior experience.

<p align="center">
  <img src="screenshots/hero_screenshot.png" alt="ReVoltVPN splash screen" width="32%"/>
  &nbsp;&nbsp;&nbsp;
  <img src="screenshots/styled_idle.png" alt="ReVoltVPN connected — 60 min session active" width="32%"/>
</p>

There are hundreds of free VPN apps on the Play Store. Most of them are fine honestly — some are genuinely good. But a lot of them are vague about how they work, who runs them, and what happens to your traffic. I wanted to build something where the answer to all of those questions is just... public.

So here it is.

---

## How it works
You watch a short ad. You get 60 minutes and 2GB of full-speed traffic. That's it. The ad pays for the server (actually not even enough). No accounts, no emails, no subscriptions.

When your data runs out you get throttled to 1.5 Mbps instead of getting cut off. You can watch a bonus ad to top up anytime.

---

## The stack
- **App** — Flutter (Android only for now)
- **Server** — A single Debian box rented from Hetzner, located in Finland
- **VPN protocol** — AmneziaWG, which is WireGuard with obfuscation so it works on carriers that block standard WireGuard
- **Backend** — A Python script I wrote called Hivemind that manages sessions, data quotas, and throttling
- **Ads** — Google AdMob rewarded ads, verified server-side so fake callbacks don't work

---

## Limitations (being honest)
- One server, one location (Finland). That's all I can afford right now
- 2 cores and 4GB RAM. It will not handle thousands of concurrent users
- iOS is not supported and probably won't be for a while
- Countries with very aggressive DPI (China, Russia, etc.) may still have issues
- I'm a student doing this in my free time. Expect rough edges

---

## Why I built this
Free time project. Wanted to learn how VPNs actually work under the hood. Ended up building the whole thing from scratch — the Flutter app, the AmneziaWG setup, the session management backend, the AdMob integration. It took way longer than expected.

---

## Privacy
Your traffic goes through my server in Finland. I don't log it, I don't sell it, I have no reason to. The session manager (Hivemind) only tracks whether your session is active and how much data you've used — nothing else.

Internet privacy at the cost of watching an ad. Honest business.

You can read the server code yourself, it's in this repo.

---

*ReVoltVPN is not affiliated with any VPN company.*

---
