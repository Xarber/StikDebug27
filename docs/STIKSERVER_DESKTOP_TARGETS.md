# Desktop targets through StikServer

The native StikServer picker identifies Mac, Windows and Linux hosts with a desktop icon. Desktop frame transport reuses the existing JPEG/UIImage path and fullscreen view; it does not embed the web application.

Connect StikDebug to the StikServer running on the computer, or connect that computer through another StikServer using its private link. Select the computer as the command target. Capabilities depend on the desktop adapter; iOS-only developer services cannot operate on a Mac. The current native tool interface may still offer unsupported iOS controls; these return an explicit unsupported-service error. Native capability-filtering and native Mac-specific activation-mode selection are not implemented by this change.

Mac experimental location simulation uses saved system preferences and requires approval on the Mac. Default set/reset activation is deferred until the Mac restarts, and changes may persist after disconnect. A completed command is not evidence that Core Location or Find My reports the requested position. Clear Location restores the original preferences through the server. StikServer's web Location tab also offers an experimental immediate-notification mode and a map with browser-local saved places.

Validation: the modified Swift file was parsed with the installed Swift compiler; no iOS build or physical iPhone/iPad session was performed for this change. See StikServer `docs/DESKTOP_TARGETS.md` and its test report for desktop limitations and executed checks.
