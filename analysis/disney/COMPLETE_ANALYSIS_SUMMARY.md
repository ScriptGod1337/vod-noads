# Disney+ APK v2.16.2-rc2 - Complete Domain & URL Analysis

## Executive Summary

Androguard analysis of the Disney+ APK revealed **72 unique domains** with comprehensive tracking, advertising, and infrastructure integrations. The app implements multiple layers of analytics, ad serving, and quality monitoring alongside Disney's proprietary BAMGrid streaming infrastructure.

---

## Category 1: Ad-Serving Domains (3 domains)

### Primary Ad Server
- **pubads.g.doubleclick.net** - Google DFP (DoubleClick for Publishers)
  - VAST/VMAP video ad delivery
  - Multiple test endpoints detected
  - Parameters: sz, iu, ciu_szs, ad_rule, impl, gdfp_req, env, output, cust_params, cmsid, vid, correlator
  - Includes NHL content with specific ad parameters (vpos=Preroll, ad_rule=1)

### Secondary Ad Services
- **pagead2.googlesyndication.com** - Google Ad Network
  - Pixel tracking: `/pagead/gen_204?id=gmob-apps`
  
- **www.googleadservices.com** - Google Ad Services
  - Deep link conversion tracking
  - Endpoint: `/pagead/conversion/app/deeplink`

---

## Category 2: Tracking/Beacon Domains (9 domains)

### Firebase Analytics (Google)
- **firebase.google.com** - Core Firebase platform
- **app-measurement.com** - Firebase backend for event collection

### Video Quality Experience (Conviva)
- **cws.conviva.com** - Primary gateway server
- **%s.ipv4.cws.conviva.com** - IPv4-specific gateway (parameterized)
- **%s.ipv4.testonly.conviva.com** - IPv4 test gateway
- **%s.ipv6.cws.conviva.com** - IPv6-specific gateway
- **%s.ipv6.testonly.conviva.com** - IPv6 test gateway
- **pings.conviva.com** - Beacon transmission (`/ping.ping`)

### Other Analytics
- **hal.testandtarget.omniture.com** - Adobe Test & Target (personalization)
- **accounts.google.com** - Google OAuth2 authentication

---

## Category 3: Disney Content/Infrastructure Domains (31 domains)

### Core Disney+ Domains
- **disneyplus.com** - Primary domain (`/downloads` endpoint)
- **www.disneyplus.com** - Web-facing domain

### Star+ Regional Platform
- **starplus.com** - Regional streaming platform
- **startlus.com** - Regional variant (likely typo)
- **help.starplus.com** - Support domain

### BAMTech/BAMGrid Infrastructure (13 domains)

**Configuration Servers:**
- **bam-sdk-configs.bamgrid.com** - Production
- **dev-bam-sdk-configs.bamgrid.com** - Development
- **staging-bam-sdk-configs.bamgrid.com** - Staging

**API Endpoints:**
- **star.api.edge.bamgrid.com** - Production Star+ API
- **qa-star.api.edge.bamgrid.com** - QA Star+ API
- **global.edge.bamgrid.com** - Global edge API
- **qa.global.edge.bamgrid.com** - QA global edge API

**Services:**
- **lw.bamgrid.com** - Lightweight service
- **pcs.bamgrid.com** - Playback Control Service
- **vpe-static-dev-bamgrid-com-pcs.bamgrid.com** - VPE static content
- **github.bamtech.co** - Schema registry (event definitions)
- **xce-pluck-ui.us-east-1.bamgrid.net** - Experience monitoring

### Content Delivery (5 domains)
- **prod-ripcut-delivery.disney-plus.net** - Production CDN
- **qa-ripcut-delivery.disney-plus.net** - QA CDN
- **appconfigs.disney-plus.net** - App configuration
- **d2zihajmogu5jn.cloudfront.net** - CloudFront CDN (test content: bipbop_advanced)
- **cdn.registerdisney.go.com** - Production registration
- **stg.cdn.registerdisney.go.com** - Staging registration

---

## Category 4: Third-Party SDK Domains (16 domains)

### Braze (Customer Engagement)
- **sdk.iad-01.braze.com** - US-East SDK endpoint (`/api/v3/`)
- **sondheim.braze.com** - Service endpoint (`/api/v3/`)
- **www.braze.com** - Documentation

### Sentry (Error/Crash Reporting)
- **a08a5a5931d945e2b7a90c9f10818063@disney.my.sentry.io** - Disney Sentry project (endpoint: `/57`)

### Cloud & Distribution
- **install.appcenter.ms** - Microsoft App Center
- **s3.amazonaws.com** - AWS S3 storage

### App Stores & Retail
- **apps.apple.com** - Apple App Store
- **play.google.com** - Google Play Store
- **www.amazon.com** / **www.amazon.ca** / **www.amazon.com.au** - Amazon retail

### Google Services
- **www.googleapis.com** - Google APIs (OAuth, Games API)
- **github.com** - GitHub (code hosting)
- **issuetracker.google.com** - Google Issue Tracker

### Content Partners
- **www.nhl.com** - National Hockey League integration

---

## Category 5: Standards & Specification Domains (8 domains)

- **dashif.org** - DASH Industry Forum (streaming standard)
- **aomedia.org** - Alliance for Open Media
- **www.w3.org** - World Wide Web Consortium
- **schemas.android.com** - Android XML namespaces
- **schemas.microsoft.com** - Microsoft XML namespaces
- **exoplayer.dev** - Google ExoPlayer documentation
- **developer.android.com** - Android developer docs
- **developer.apple.com** - Apple developer docs

---

## Category 6: Miscellaneous Domains (5 domains)

- **goo.gl** - Google URL shortener
- **google.com** - Google search integration
- **localhost** - Local development
- **appassets.androidplatform.net** - Android platform resources
- **ns.adobe.com** - Adobe namespace definitions

---

## Key Technical Findings

### 1. Advertising Infrastructure
- **Ad Server**: Google DoubleClick/DFP is the exclusive ad server
- **Ad Format**: VAST and VMAP protocols for video ads
- **Ad Insertion**: Pre-roll ads (vpos=Preroll) with ad rules enabled
- **Test Content**: Multiple test ad URLs with parameterized configurations
- **Sports Content**: NHL content with specific ad targeting parameters

### 2. Video Quality Monitoring
- **Primary QoE Platform**: Conviva with multiple geographic gateways
- **IPv4/IPv6 Support**: Separate endpoints for IPv4 and IPv6 with test variants
- **Beacon Tracking**: Continuous QoE metrics via `pings.conviva.com/ping.ping`
- **Personalization**: Adobe Test & Target integration (hal.testandtarget.omniture.com)

### 3. Analytics & Tracking
- **Google Firebase**: Real-time event tracking and remote config
- **App Measurement**: Firebase backend for event data collection
- **Conversion Tracking**: Deep link tracking via googleadservices.com

### 4. Streaming Infrastructure (BAMTech)
- **Multi-Environment**: Production, QA, staging, and development tiers
- **Edge Distribution**: Global edge servers with regional variants
- **Playback Control**: Dedicated service for stream management (pcs.bamgrid.com)
- **Experience Monitoring**: Error reporting via XCE Pluck UI
- **Schema Registry**: Event definitions in github.bamtech.co

### 5. SDK Integrations
| SDK | Purpose | Endpoints |
|-----|---------|-----------|
| Braze | Push notifications, engagement | sdk.iad-01.braze.com, sondheim.braze.com |
| Sentry | Error/crash reporting | disney.my.sentry.io |
| Firebase | Analytics, config | firebase.google.com, app-measurement.com |
| Conviva | QoE metrics | cws.conviva.com, pings.conviva.com |
| Microsoft App Center | Distribution, analytics | install.appcenter.ms |

---

## Ad-Related String Findings

The androguard analysis also extracted embedded ad-related code strings:
- AdPodData, AdPodPlacement, AdServerRequest (ad structures)
- AdPodFetchedEvent, AdPodRequestedEvent (ad lifecycle events)
- PodRequest, PodResponse (pod management)
- Beacon timeout and response configurations
- Sample VAST/VMAP URLs from Google DFP with test parameters

---

## Data Collection Summary

The Disney+ app collects data through:

1. **Performance Metrics**: Conviva QoE, Firebase events
2. **User Behavior**: Firebase Analytics, deep link conversions
3. **Advertising**: DoubleClick impression tracking, ad rules
4. **Error Reporting**: Sentry crash reports, ExoPlayer errors
5. **Engagement**: Braze push notifications and messaging
6. **Distribution**: App Center telemetry

---

## Files Generated

1. `/tmp/disney_analysis.txt` - Detailed analysis with explanation
2. `/tmp/disney_domains_categorized.csv` - CSV format for import/processing
3. `/tmp/all_domains.txt` - Simple domain list (72 domains)
4. `/tmp/COMPLETE_ANALYSIS_SUMMARY.md` - This summary

