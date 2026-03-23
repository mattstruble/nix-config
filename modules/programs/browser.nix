{ ... }:
{
  flake.modules.homeManager.browser =
    { pkgs, lib, ... }:
    let
      lock-false = {
        Value = false;
        status = "locked";
      };
      lock-true = {
        Value = true;
        Status = "locked";
      };
    in
    {
      programs.firefox = {
        enable = true;
        package = pkgs.wrapFirefox pkgs.firefox-unwrapped {
          extraPolicies = {
            AppAutoUpdate = false;
            AutofillCreditCardEnabled = false;
            BackgroundAppUpdate = false;
            DefaultDownloadDirectory = "~/Downloads/";
            DisableAccounts = true;
            DisableFirefoxScreenshots = true;
            DisableFirefoxStudies = true;
            DisableForgetButton = true;
            DisableFormHistory = true;
            DisableMasterPasswordCreation = true;
            DisablePasswordReveal = true;
            DisableProfileImport = true;
            DisableProfileRefresh = false;
            DisablePocket = true;
            DisableTelemetry = true;
            DisplayBookmarksToolbar = "never";
            DisplayMenuBar = "default-off";
            EnableTrackingProtection = {
              Value = true;
              Locked = true;
              Cryptomining = true;
              Fingerprinting = true;
              EmailTracking = true;
            };
            EncryptedMediaExtensions = {
              Enabled = true;
              Locked = true;
            };
            FirefoxHome = {
              Search = true;
              TopSites = true;
              SponsoredTopSites = false;
              Highlights = true;
              Pocket = false;
              SponsoredPocket = false;
              Snippets = false;
              Locked = true;
            };
            FirefoxSuggest = {
              WebSuggestions = false;
              SponsoredSuggestions = false;
              ImproveSuggest = false;
              Locked = true;
            };
            HardwareAcceleration = false;
            Homepage = {
              URL = "https://daily.dev";
              Locked = true;
              StartPage = "homepage";
            };
            HttpsOnlyMode = "force_enabled";
            NoDefaultBookmarks = true;
            OfferToSaveLogins = false;
            OverrideFirstRunPage = "";
            OverridePostUpdatePage = "";
            DontCheckDefaultBrowser = true;
            PasswordManagerEnabled = false;
            PDFjs = {
              Enabled = false;
              EnablePermissions = false;
            };
            PictureInPicture = lock-true;
            SanitizeOnShutdown = {
              Cache = true;
              Cookies = false;
              Downloads = true;
              FormData = true;
              History = false;
              Sessions = false;
              SiteSettings = false;
              OfflineApps = true;
              Locked = true;
            };
            SearchBar = "unified";
            SearchEngines = {
              Remove = [ "Amazon.com" "Bing" "Google" ];
              Default = "DuckDuckGo";
              DefaultPrivate = "DuckDuckGo";
            };
            SearchSuggestEnabled = false;
            ShowHomeButton = false;
            StartDownloadsInTempDirectory = true;
            TranslateEnabled = true;
            UserMessaging = {
              ExtensionRecommendations = false;
              FeatureRecommendations = false;
              MoreFromMozilla = false;
              SkipOnbording = true;
              UrlbarInterventions = false;
              WhatsNew = false;
              Locked = true;
            };

            ExtensionSettings =
              with builtins;
              let
                extension = shortId: uuid: {
                  name = uuid;
                  value = {
                    install_url = "https://addons.mozilla.org/en-US/firefox/downloads/latest/${shortId}/latest.xpi";
                    installation_mode = "normal_installed";
                  };
                };
              in
              listToAttrs [
                (extension "ublock-origin" "uBlock0@raymondhill.net")
                (extension "clearurls" "{74145f27-f039-47ce-a470-a662b129930a}")
                (extension "1password-x-password-manager" "{d634138d-c276-4fc8-924b-40a0ea21d284}")
                (extension "facebook-container" "@contain-facebook")
                (extension "code-finder-catalyzex" "{a3f8e50c-bc39-4e48-ae2f-2ed36fa6752b}")
                (extension "arxiv-vanity" "{e92bf629-488c-4d5f-8771-04812b17c143}")
                (extension "auto-tab-discard" "{c2c003ee-bd69-42a2-b0e9-6f34222cb046}")
                (extension "dearrow" "deArrow@ajay.app")
                (extension "disable-twitch-extensions" "disable-twitch-extensions@rootonline.de")
                (extension "enhancer-for-youtube" "enhancerforyoutube@maximerf.addons.mozilla.org")
                (extension "private-relay" "private-relay@firefox.com")
                (extension "gnu_terry_pratchett" "jid1-HGPgB0x6133Hig@jetpack")
                (extension "imagus" "{00000f2a-7cde-4f20-83ed-434fcb420d71}")
                (extension "old-reddit-redirect" "{9063c2e9-e07c-4c2c-9646-cfe7ca8d0498}")
                (extension "skip-redirect" "skipredirect@sblask")
                (extension "sponsorblock" "sponsorBlocker@ajay.app")
                (extension "unpaywall" "{f209234a-76f0-4735-9920-eb62507a54cd}")
                (extension "vimium-ff" "{d7742d87-e61d-4b78-b8a1-b469842139fa}")
                (extension "random_user_agent" "{b43b974b-1d3a-4232-b226-eaa2ac6ebb69}")
                (extension "refined-github-" "{a4c4eda4-fb84-4a84-b4a1-f7c1cbf2a1ad}")
                (extension "spoof-geolocation" "{61173a74-ece7-4ef3-86a7-525538b78430}")
                (extension "trackmenot" "trackmenot@mrl.nyu.edu")
              ];

            "3rdparty".Extensions = {
              "uBlock0@raymondhill.net".adminSettings = {
                userSettings = rec {
                  cloudStorageEnabled = lib.mkForce false;
                  importedLists = [
                    "https://big.oisd.nl"
                    "https://github.com/DandelionSprout/adfilt/raw/master/LegitimateURLShortener.txt"
                    "https://raw.githubusercontent.com/mchangrh/yt-neuter/main/yt-neuter.txt"
                    "https://raw.githubusercontent.com/mchangrh/yt-neuter/main/filters/sponsorblock.txt"
                    "https://raw.githubusercontent.com/mchangrh/yt-neuter/main/filters/noview.txt"
                  ];
                  externalLists = lib.concatStringsSep "\n" importedLists;
                };
                selectedFilterLists = [
                  "adguard-annoyance" "adguard-cookies" "adguard-generic" "adguard-mobile"
                  "adguard-mobile-app-banners" "adguard-other-annoyances" "adguard-popup-overlays"
                  "adguard-social" "adguard-spyware" "adguard-spyware-url" "adguard-widgets"
                  "block-lan" "curben-phishing" "dpollock-0" "easylist" "easyprivacy" "plowe-0"
                  "ublock-abuse" "ublock-annoyances" "ublock-cookies-adguard" "ublock-badware"
                  "ublock-filters" "ublock-privacy" "ublock-quick-fixes" "ublock-unbreak" "urlhaus-1"
                  "https://big.oisd.nl"
                  "https://github.com/DandelionSprout/adfilt/raw/master/LegitimateURLShortener.txt"
                  "https://raw.githubusercontent.com/mchangrh/yt-neuter/main/yt-neuter.txt"
                  "https://raw.githubusercontent.com/mchangrh/yt-neuter/main/filters/sponsorblock.txt"
                  "https://raw.githubusercontent.com/mchangrh/yt-neuter/main/filters/noview.txt"
                ];
                hiddenSettings = {
                  userResourceLocation = "https://raw.githubusercontent.com/mchangrh/yt-neuter/main/scriptlets.js";
                };
              };

              Preferences = {
                "beacon.enabled" = false;
                "browser.topsites.contile.enabled" = lock-false;
                "browser.formfill.enable" = lock-false;
                "browser.search.suggest.enabled" = lock-false;
                "browser.search.suggest.enabled.private" = lock-false;
                "browser.urlbar.suggest.searches" = lock-false;
                "browser.urlbar.showSearchSuggestionsFirst" = lock-false;
                "browser.newtabpage.activity-stream.feeds.section.topstories" = lock-false;
                "browser.newtabpage.activity-stream.feeds.snippets" = lock-false;
                "browser.newtabpage.activity-stream.section.highlights.includePocket" = lock-false;
                "browser.newtabpage.activity-stream.section.highlights.includeBookmarks" = lock-false;
                "browser.newtabpage.activity-stream.section.highlights.includeDownloads" = lock-false;
                "browser.newtabpage.activity-stream.section.highlights.includeVisited" = lock-false;
                "browser.newtabpage.activity-stream.showSponsored" = lock-false;
                "browser.newtabpage.activity-stream.system.showSponsored" = lock-false;
                "browser.newtabpage.activity-stream.showSponsoredTopSites" = lock-false;
                "browser.newtabpage.activity-stream.telemetry" = lock-false;
                "browser.preferences.defaultPerformanceSettings.enabled" = false;
                "browser.send_pings" = false;
                "browser.urlbar.speculativeConnect.enabled" = lock-false;
                "cookiebanners.service.mode" = 1;
                "cookiebanners.service.mode.privateBrowsing" = 1;
                "dom.event.clipboardevents.enabled" = lock-true;
                "extensions.pocket.enabled" = lock-false;
                "extensions.screenshots.disabled" = lock-true;
                "extensions.formautofill.addresses.enabled" = lock-false;
                "geo.enabled" = lock-false;
                "layers.acceleration.disabled" = true;
                "media.autoplay.blocking_policy" = 2;
                "media.navigator.enabled" = lock-false;
                "media.peerconnection.enabled" = lock-false;
                "media.videocontrols.picture-in-picture.enable-when-switching-tabs.enabled" = lock-true;
                "network.cookie.cookieBehavior" = 4;
                "permissions.default.geo" = 3;
                "privacy.bounceTrackingProtection.mode" = 1;
                "privacy.donottrackheader.enabled" = true;
                "privacy.fingerprintingProtection" = lock-true;
                "privacy.firstparty.isolate" = true;
                "privacy.globalprivacycontrol.enabled" = lock-true;
                "privacy.resistFingerprinting" = true;
                "privacy.resistFingerprinting.letterboxing" = true;
                "privacy.trackingprotection.socialtracking.enabled" = lock-true;
                "sidebar.verticalTabs" = true;
                "sidebar.revamp" = true;
                "sidebar.backupState" = {
                  "command" = "";
                  "launcherExpanded" = false;
                  "launcherVisible" = false;
                };
                "sidebar.visibility" = "always-show";
                "signon.management.page.breach-alerts.enabled" = false;
                "webgl.disabled" = true;
              };
            };
          };
        };
      };
    };
}
