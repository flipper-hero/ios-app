# FlipperHero Privacy Policy / Datenschutzerklärung

Last updated / Stand: 9 October 2026

## English

FlipperHero is published by anycast.io UG (haftungsbeschrankt). It has no
FlipperHero account or login, no advertising, and no integrated analytics or
crash-reporting service. The app does not send data to a FlipperHero backend.
Optional AI requests go to the provider you select, as described below.

### Data on your devices

The app connects directly to your Flipper Zero over Bluetooth. Preferences,
remembered devices, cached device inventories and the action audit log are stored
on your iPhone. Conversations are held in app memory. API keys are stored separately
for each provider in the iOS Keychain and can be removed in Settings. Keychain entries may
survive uninstalling the app, so remove the key in Settings before uninstalling
if you want to remove it. Other app-local data is removed when you delete the
app rather than offloading it; any device backups are managed by iOS.

### Optional AI features and external services

AI chat requires your own provider account, API key and any applicable provider
credits. Choose OpenRouter, 2342.ai, Blackbit, OrcaRouter, Z.ai, Kimi, Qwen Cloud
or MiniMax in Settings. Requests go directly from your iPhone to the selected service over HTTPS,
authenticated with your key. Requests include the conversation, any attached
photos, device inventory information, and results of agent actions, which may
include file names, file contents and Flipper screen images. Routing services may forward
requests to the selected model provider. These services can associate requests
with your provider account and receive network information such as your IP
address. No separate copy is sent to a FlipperHero backend.

Each service and its model providers have their own retention, processing and model
training policies. Review the privacy policy of your selected service and its
model providers before using AI features. Provider documentation is linked in Settings. Do not send
secrets or personal information you do not want those services to process.
Removing a key or starting a new chat does not delete data held by those services;
use their privacy and deletion procedures for such requests.

Loading the model catalog sends your key and ordinary network information to the
selected service. Testing and saving sends only a fixed short test prompt, with
no conversation, photos or device data. The test may incur provider charges.
Changing providers starts a fresh model conversation; previous chat history is not forwarded.

Catalog searches, firmware checks and downloads contact the official Flipper app
catalog, GitHub or the requested download host. Those hosts receive the request
and ordinary network information. The app does not upload your Flipper files to
these hosts as part of browsing or downloading.

### Camera, microphone and speech

Camera and photo access are optional and used to attach images to your message.
Attached images are sent with an AI request. Microphone and speech permissions
are optional and used to turn speech into text. Speech recognition runs on-device
when supported; otherwise Apple's speech-recognition service may process the
audio. The resulting text is sent when you submit your message. Read-aloud uses
the system speech synthesizer.

### Support and privacy questions

Support is available through [GitHub Issues](https://github.com/flipper-hero/ios-app/issues).
Issues are public. Do not include API keys, private files or personal information.
GitHub processes information you submit under its own privacy policy. For a
private privacy request, contact the publisher using the contact details on the
app's App Store developer page.

## Deutsch

FlipperHero wird von anycast.io UG (haftungsbeschrankt) veröffentlicht. Die App
hat kein eigenes Benutzerkonto und keinen Login, keine Werbung und keine
integrierten Dienste für Nutzungsanalyse oder Absturzberichte. Die App sendet
keine Daten an ein FlipperHero-Backend. Optionale KI-Anfragen gehen an den von
dir gewählten Anbieter, wie unten beschrieben.

### Daten auf deinen Geräten

Die App verbindet sich per Bluetooth direkt mit deinem Flipper Zero.
Einstellungen, bekannte Geräte, zwischengespeicherte Geräteinventare und das
Aktionsprotokoll werden auf deinem iPhone gespeichert. Gespräche bleiben im
Arbeitsspeicher der App. API-Schlüssel liegen pro Anbieter getrennt im iOS-Schlüsselbund
und lassen sich in den Einstellungen entfernen. Einträge im Schlüsselbund können
eine Deinstallation überstehen. Entferne den Schlüssel deshalb vorher in den
Einstellungen, wenn du ihn löschen möchtest. Andere lokale App-Daten werden beim
Löschen der App entfernt, beim Auslagern hingegen nicht. Gerätesicherungen
verwaltet iOS.

### Optionale KI-Funktionen und externe Dienste

Der KI-Chat benötigt ein eigenes Anbieterkonto, einen API-Schlüssel und
gegebenenfalls Guthaben beim Anbieter. In den Einstellungen kannst du OpenRouter,
2342.ai, Blackbit, OrcaRouter, Z.ai, Kimi, Qwen Cloud oder MiniMax auswählen.
Anfragen gehen per HTTPS direkt von deinem iPhone an den gewählten Dienst und werden mit deinem Schlüssel authentifiziert. Sie
enthalten den Gesprächsverlauf, angehängte Fotos, Geräteinventar und Ergebnisse
der Agent-Aktionen. Dazu können Dateinamen, Dateiinhalte und Bildschirmbilder des
Flippers gehören. Routing-Dienste können die Anfragen an den gewählten Modellanbieter
weiterleiten. Diese Dienste können Anfragen deinem Anbieterkonto zuordnen und
erhalten Netzwerkdaten wie deine IP-Adresse. Eine zusätzliche Kopie wird nicht
an ein FlipperHero-Backend gesendet.

Für Speicherung, Verarbeitung und Modelltraining gelten die Regeln des
gewählten Dienstes und seiner Modellanbieter. Lies vor der Nutzung deren
Datenschutzerklärungen. Die Anbieter-Dokumentation ist in den Einstellungen verlinkt.
Sende keine Geheimnisse oder personenbezogenen Daten, die diese
Dienste nicht verarbeiten sollen. Das Entfernen des Schlüssels oder ein neuer
Chat löscht keine Daten bei diesen Diensten. Nutze dafür deren Datenschutz- und
Löschverfahren.

Beim Laden der Modellliste werden dein Schlüssel und übliche Netzwerkdaten an
den gewählten Dienst übertragen. Beim Testen und Speichern wird nur eine feste,
kurze Testnachricht gesendet, ohne Gesprächsverlauf, Fotos oder Gerätedaten.
Dabei können Kosten beim Anbieter entstehen. Ein Anbieterwechsel beginnt einen
neuen Modell-Chat; der bisherige Gesprächsverlauf wird nicht weitergeleitet.

Katalogsuchen, Firmwareprüfungen und Downloads kontaktieren den offiziellen
Flipper-App-Katalog, GitHub oder den angefragten Download-Host. Diese erhalten die
Anfrage und übliche Netzwerkdaten. Beim Durchsuchen oder Herunterladen lädt die
App keine Flipper-Dateien zu diesen Hosts hoch.

### Kamera, Mikrofon und Spracherkennung

Kamera und Fotozugriff sind optional und dienen zum Anhängen von Bildern an
Nachrichten. Angehängte Bilder werden mit der KI-Anfrage übertragen. Mikrofon
und Spracherkennung sind optional und wandeln Sprache in Text um. Wenn
unterstützt, erfolgt die Erkennung auf dem Gerät; andernfalls kann Apples
Spracherkennungsdienst die Audiodaten verarbeiten. Der erkannte Text wird beim
Absenden der Nachricht übertragen. Das Vorlesen verwendet die Sprachsynthese des
Betriebssystems.

### Support und Datenschutzfragen

Support gibt es über [GitHub Issues](https://github.com/flipper-hero/ios-app/issues).
Issues sind öffentlich. Veröffentliche dort keine API-Schlüssel, privaten Dateien
oder personenbezogenen Daten. GitHub verarbeitet eingereichte Informationen nach
seiner eigenen Datenschutzerklärung. Für private Datenschutzanfragen nutze die
Kontaktdaten des Herausgebers auf der Entwicklerseite im App Store.
