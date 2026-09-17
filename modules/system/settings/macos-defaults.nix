{ ... }:
{
  flake.modules.darwin.macos-defaults = {
    system = {
      defaults = {
        ".GlobalPreferences" = {
          "com.apple.mouse.scaling" = 1.0;
        };

        NSGlobalDomain = {
          AppleInterfaceStyle = "Dark";
          AppleInterfaceStyleSwitchesAutomatically = false;
          AppleKeyboardUIMode = 3;
          AppleMeasurementUnits = "Inches";
          AppleMetricUnits = 0;
          ApplePressAndHoldEnabled = false;
          AppleShowAllExtensions = true;
          AppleTemperatureUnit = "Fahrenheit";
          NSAutomaticWindowAnimationsEnabled = false;
          NSNavPanelExpandedStateForSaveMode = true;
          NSNavPanelExpandedStateForSaveMode2 = true;
          "com.apple.keyboard.fnState" = true;
          _HIHideMenuBar = true;
          "com.apple.mouse.tapBehavior" = 1;
          "com.apple.sound.beep.volume" = 0.0;
          "com.apple.sound.beep.feedback" = 0;
        };

        CustomUserPreferences = {
          "com.apple.finder" = {
            ShowExternalHardDrivesOnDesktop = false;
            ShowHardDrivesOnDesktop = false;
            ShowMountedServersOnDesktop = true;
            ShowRemovableMediaOnDesktop = true;
            _FXSortFoldersFirst = true;
            FXDefaultSearchScope = "SCcf";
          };

          "com.apple.desktopservices" = {
            DSDontWriteNetworkStores = true;
            DSDontWriteUSBStores = true;
          };

          "com.apple.spaces" = {
            "spans-displays" = 0;
          };

          "com.apple.WindowManager" = {
            EnableStandardClickToShowDesktop = 0;
            StandardHideDesktopIcons = 0;
            HideDesktop = 0;
            StageManagerHideWidgets = 0;
            StandardHideWidgets = 0;
          };

          "com.apple.screencapture" = {
            location = "~/Downloads";
            type = "png";
          };

          "com.apple.AdLib" = {
            allowApplePersonalizedAdvertising = false;
          };

          "com.apple.ImageCapture".disableHotPlug = true;

          "com.apple.print.PrintingPrefs" = {
            "Quit When Finished" = true;
          };

          "com.apple.SoftwareUpdate" = {
            AutomaticCheckEnabled = true;
            ScheduleFrequency = 1;
            AutomaticDownload = 1;
            CriticalUpdateInstall = 1;
          };

          "com.apple.TimeMachine".DoNotOfferNewDisksForBackup = true;
          "com.apple.commerce".AutoUpdate = true;

          dock = {
            autohide = true;
            expose-group-by-app = false;
            largesize = 64;
            launchanim = false;
            magnification = true;
            mineffect = "genie";
            mru-spaces = false;
            orientation = "bottom";
            show-process-indicators = true;
            show-recents = false;
            static-only = true;
            tilesize = 32;
            wvous-bl-corner = "Disabled";
            wvous-br-corner = "Disabled";
            wvous-tr-corner = "Disabled";
            wvous-tl-corner = "Disabled";
          };

          finder = {
            AppleShowAllExtensions = true;
            CreateDesktop = false;
            FXEnableExtensionChangeWarning = false;
            ShowPathbar = true;
          };

          trackpad = {
            Clicking = false;
            TrackpadThreeFingerDrag = true;
          };
        };
      };

      keyboard = {
        enableKeyMapping = true;
        remapCapsLockToEscape = true;
      };
    };
  };
}
