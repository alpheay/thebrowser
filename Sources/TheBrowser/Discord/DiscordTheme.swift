import Foundation

/// CSS + JS we inject into the embedded Discord web client at document start
/// so the page renders in The Browser's matte palette from the very first
/// paint (no flash of blurple).
///
/// Strategy:
/// 1. Override Discord's CSS custom properties (`--background-primary`,
///    `--brand-experiment`, …). These names are public theming surface and
///    are far more stable across Discord's redesigns than the hashed class
///    names (`.container_a4d4d9`) that ship in the rendered HTML.
/// 2. Hide redundant chrome (Discord's own server rail) using attribute
///    selectors (`nav[aria-label*="Servers"]`) and substring class matches
///    (`[class*="guilds_"]`). Both survive Discord's class-name rotation
///    better than full hashes.
/// 3. Swap the gg sans font family for SF Pro so the embed types in the
///    same voice as the rest of the app.
///
/// When Discord changes a token name out from under us, the worst case is a
/// patch of native dark — the page itself still works.
enum DiscordTheme {
    static let injectionScript: String = """
    (function () {
        const css = `\(themeCSS)`;
        function apply() {
            if (document.getElementById('thebrowser-discord-theme')) return;
            const style = document.createElement('style');
            style.id = 'thebrowser-discord-theme';
            style.textContent = css;
            (document.head || document.documentElement).appendChild(style);
            // Force dark; the user's Discord theme preference would otherwise
            // bleed in if they picked Light or Sync With Computer.
            try {
                document.documentElement.classList.add('theme-dark');
                document.documentElement.classList.remove('theme-light');
            } catch (_) {}
        }
        apply();
        // Discord's SPA occasionally re-renders the <html> attributes; re-apply
        // the dark class on any subtree mutation so our overrides keep biting.
        try {
            new MutationObserver(() => {
                if (!document.documentElement.classList.contains('theme-dark')) {
                    document.documentElement.classList.add('theme-dark');
                    document.documentElement.classList.remove('theme-light');
                }
                if (!document.getElementById('thebrowser-discord-theme')) apply();
            }).observe(document.documentElement, { attributes: true, childList: true, subtree: false });
        } catch (_) {}
    })();
    """

    /// The actual CSS payload. Pulled out of the JS literal so the IDE can
    /// syntax-highlight most of it.
    private static let themeCSS: String = #"""
    /* ---- Color tokens ---- */
    :root,
    html,
    .theme-dark,
    .theme-darker,
    .theme-light {
        /* Plates — pure matte black */
        --background-primary: #0A0A0A;
        --background-secondary: #050505;
        --background-secondary-alt: #050505;
        --background-tertiary: #050505;
        --background-floating: #131313;
        --background-accent: #181818;
        --background-nested-floating: #131313;
        --background-mobile-primary: #0A0A0A;
        --background-mobile-secondary: #050505;

        /* Hover / active scrims */
        --background-modifier-hover: rgba(255,255,255,0.04);
        --background-modifier-active: rgba(255,255,255,0.08);
        --background-modifier-selected: rgba(255,255,255,0.10);
        --background-modifier-accent: rgba(255,255,255,0.06);
        --background-message-hover: rgba(255,255,255,0.03);
        --background-message-highlight: rgba(255,255,255,0.04);

        /* Channel chrome */
        --channels-default: rgba(255,255,255,0.62);
        --channel-text-area-placeholder: rgba(255,255,255,0.40);
        --channeltextarea-background: #131313;
        --activity-card-background: #131313;

        /* Strokes */
        --border-faint: rgba(255,255,255,0.04);
        --border-subtle: rgba(255,255,255,0.08);
        --border-strong: rgba(255,255,255,0.14);

        /* Text */
        --header-primary: rgba(255,255,255,0.95);
        --header-secondary: rgba(255,255,255,0.62);
        --text-normal: rgba(255,255,255,0.85);
        --text-muted: rgba(255,255,255,0.40);
        --text-faint: rgba(255,255,255,0.22);
        --text-link: rgba(255,255,255,0.95);
        --text-link-low-saturation: rgba(255,255,255,0.62);
        --text-positive: rgba(255,255,255,0.85);
        --text-warning: rgba(255,255,255,0.85);
        --text-danger: rgba(255,180,180,0.85);
        --text-brand: rgba(255,255,255,0.95);

        /* Interactive */
        --interactive-normal: rgba(255,255,255,0.62);
        --interactive-hover: rgba(255,255,255,0.95);
        --interactive-active: rgba(255,255,255,1.0);
        --interactive-muted: rgba(255,255,255,0.22);

        /* Brand — strip the blurple */
        --brand-experiment: #ffffff;
        --brand-experiment-560: #ffffff;
        --brand-experiment-500: #ffffff;
        --brand-experiment-400: #ffffff;
        --brand-experiment-300: rgba(255,255,255,0.92);
        --brand-experiment-200: rgba(255,255,255,0.80);
        --brand-experiment-100: rgba(255,255,255,0.62);
        --brand-experiment-15a: rgba(255,255,255,0.15);
        --brand-experiment-30a: rgba(255,255,255,0.20);
        --brand-experiment-60a: rgba(255,255,255,0.30);
        --brand-500: #ffffff;
        --brand-560: #ffffff;

        /* Status (keep destructive red faintly tinted) */
        --status-positive: rgba(255,255,255,0.85);
        --status-warning: rgba(255,255,255,0.85);
        --status-danger: rgba(255,150,150,0.90);
        --status-danger-background: rgba(255,80,80,0.18);

        /* Scrollbars */
        --scrollbar-thin-thumb: rgba(255,255,255,0.10);
        --scrollbar-thin-track: transparent;
        --scrollbar-auto-thumb: rgba(255,255,255,0.10);
        --scrollbar-auto-track: transparent;
        --scrollbar-auto-scrollbar-color-thumb: rgba(255,255,255,0.10);
        --scrollbar-auto-scrollbar-color-track: transparent;

        /* Fonts — match the rest of the app */
        --font-primary: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
        --font-display: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Helvetica Neue", sans-serif;
        --font-headline: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Helvetica Neue", sans-serif;
        --font-code: ui-monospace, "SF Mono", Menlo, monospace;
    }

    /* ---- Hard floor backgrounds ---- */
    html, body {
        background: #0A0A0A !important;
    }

    /* ---- Hide upsell banners only ---- */
    /* We previously also hid Discord's own server rail to deduplicate with
       ours, but Discord's flex layout is fragile: `display: none`-ing the
       rail collapsed the DM sidebar and main content into a zero-height
       black void on /channels/@me. The redundancy of two rails is the
       lesser evil. Promo banners stay hidden — they're floating elements,
       removing them doesn't cascade.                                       */
    [class*="upsellBanner"],
    [class*="nitroUpsell"],
    [class*="premiumBanner"],
    [class*="freeTrialBanner"] {
        display: none !important;
    }

    /* ---- Scrollbar styling (WebKit) ---- */
    ::-webkit-scrollbar {
        width: 8px;
        height: 8px;
    }
    ::-webkit-scrollbar-track {
        background: transparent;
    }
    ::-webkit-scrollbar-thumb {
        background: rgba(255,255,255,0.10);
        border-radius: 4px;
    }
    ::-webkit-scrollbar-thumb:hover {
        background: rgba(255,255,255,0.18);
    }

    /* ---- Focus rings — keep them but in our palette ---- */
    :focus-visible {
        outline: 2px solid rgba(255,255,255,0.40) !important;
        outline-offset: 1px !important;
    }

    /* ---- Force gg sans → SF on every node Discord locks inline ---- */
    body, button, input, textarea, select {
        font-family: var(--font-primary) !important;
    }
    """#
}
