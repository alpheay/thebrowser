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
    ///
    /// Every variable declaration carries `!important`. Without it, Discord's
    /// later `.theme-dark { --background-primary: #313338 }` wins on equal
    /// specificity + cascade order (we inject at atDocumentStart, theirs
    /// loads after). The `!important` lifts our values above the cascade
    /// entirely, which is the only reliable way to override a same-class
    /// selector that comes later.
    private static let themeCSS: String = #"""
    /* ---- Color tokens (forced) ---- */
    :root,
    html,
    html.theme-dark,
    html.theme-darker,
    html.theme-light,
    html.theme-pure-dark,
    .theme-dark,
    .theme-darker,
    .theme-light,
    .theme-pure-dark,
    [class*="visual-refresh"] {
        /* Plates — pure matte black */
        --background-primary: #0A0A0A !important;
        --background-secondary: #050505 !important;
        --background-secondary-alt: #050505 !important;
        --background-tertiary: #050505 !important;
        --background-floating: #131313 !important;
        --background-accent: #181818 !important;
        --background-nested-floating: #131313 !important;
        --background-mobile-primary: #0A0A0A !important;
        --background-mobile-secondary: #050505 !important;

        /* Hover / active scrims */
        --background-modifier-hover: rgba(255,255,255,0.04) !important;
        --background-modifier-active: rgba(255,255,255,0.08) !important;
        --background-modifier-selected: rgba(255,255,255,0.10) !important;
        --background-modifier-accent: rgba(255,255,255,0.06) !important;
        --background-message-hover: rgba(255,255,255,0.03) !important;
        --background-message-highlight: rgba(255,255,255,0.04) !important;

        /* Channel chrome */
        --channels-default: rgba(255,255,255,0.62) !important;
        --channel-text-area-placeholder: rgba(255,255,255,0.40) !important;
        --channeltextarea-background: #131313 !important;
        --activity-card-background: #131313 !important;

        /* Strokes */
        --border-faint: rgba(255,255,255,0.04) !important;
        --border-subtle: rgba(255,255,255,0.08) !important;
        --border-strong: rgba(255,255,255,0.14) !important;

        /* Text */
        --header-primary: rgba(255,255,255,0.95) !important;
        --header-secondary: rgba(255,255,255,0.62) !important;
        --text-normal: rgba(255,255,255,0.85) !important;
        --text-muted: rgba(255,255,255,0.40) !important;
        --text-faint: rgba(255,255,255,0.22) !important;
        --text-link: rgba(255,255,255,0.95) !important;
        --text-link-low-saturation: rgba(255,255,255,0.62) !important;
        --text-positive: rgba(255,255,255,0.85) !important;
        --text-warning: rgba(255,255,255,0.85) !important;
        --text-danger: rgba(255,180,180,0.85) !important;
        --text-brand: rgba(255,255,255,0.95) !important;

        /* Interactive */
        --interactive-normal: rgba(255,255,255,0.62) !important;
        --interactive-hover: rgba(255,255,255,0.95) !important;
        --interactive-active: rgba(255,255,255,1.0) !important;
        --interactive-muted: rgba(255,255,255,0.22) !important;

        /* Brand — strip the blurple */
        --brand-experiment: #ffffff !important;
        --brand-experiment-560: #ffffff !important;
        --brand-experiment-500: #ffffff !important;
        --brand-experiment-400: #ffffff !important;
        --brand-experiment-300: rgba(255,255,255,0.92) !important;
        --brand-experiment-200: rgba(255,255,255,0.80) !important;
        --brand-experiment-100: rgba(255,255,255,0.62) !important;
        --brand-experiment-15a: rgba(255,255,255,0.15) !important;
        --brand-experiment-30a: rgba(255,255,255,0.20) !important;
        --brand-experiment-60a: rgba(255,255,255,0.30) !important;
        --brand-500: #ffffff !important;
        --brand-560: #ffffff !important;

        /* Status (grayscale w/ a faint red kept for danger) */
        --status-positive: rgba(255,255,255,0.85) !important;
        --status-warning: rgba(255,255,255,0.55) !important;
        --status-danger: rgba(255,150,150,0.90) !important;
        --status-danger-background: rgba(255,80,80,0.18) !important;
        --status-online: rgba(255,255,255,0.85) !important;
        --status-idle: rgba(255,255,255,0.45) !important;
        --status-dnd: rgba(255,180,180,0.85) !important;
        --status-offline: rgba(255,255,255,0.22) !important;
        --status-streaming: rgba(255,255,255,0.62) !important;

        /* Scrollbars */
        --scrollbar-thin-thumb: rgba(255,255,255,0.10) !important;
        --scrollbar-thin-track: transparent !important;
        --scrollbar-auto-thumb: rgba(255,255,255,0.10) !important;
        --scrollbar-auto-track: transparent !important;
        --scrollbar-auto-scrollbar-color-thumb: rgba(255,255,255,0.10) !important;
        --scrollbar-auto-scrollbar-color-track: transparent !important;

        /* Fonts — match the rest of the app */
        --font-primary: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif !important;
        --font-display: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Helvetica Neue", sans-serif !important;
        --font-headline: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Helvetica Neue", sans-serif !important;
        --font-code: ui-monospace, "SF Mono", Menlo, monospace !important;
    }

    /* ---- Hard floor backgrounds ---- */
    html, body {
        background: #0A0A0A !important;
    }

    /* ---- Hide the voice user-area bar at the bottom of the channel
       sidebar (mic, deafen, settings). We're not doing voice, and it
       eats vertical space.                                              */
    section[aria-label*="User area" i],
    [aria-label*="User panel" i] {
        display: none !important;
    }

    /* ---- Strip color from the small status indicators on avatars and
       in friend rows. Discord paints these via hardcoded SVG fills + via
       the --status-* variables; grayscaling the dot wrapper covers both. */
    [class*="status_"] svg,
    [class*="statusDot_"],
    [class*="statusOnline_"],
    [class*="statusIdle_"],
    [class*="statusDnd_"],
    [class*="statusOffline_"],
    [class*="statusStreaming_"] {
        filter: grayscale(1) !important;
    }

    /* ---- Hide upsell banners / promos ---- */
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
