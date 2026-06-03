# Owner Brief

Last updated: 2026-06-02

## What shipped recently

A focused round of fixes you asked for, all on the autonomous branch:

- The Override button is now a real bordered button in the brand green,
  not bare red text. Red read as danger; an override is normal.
- A plain-voice pass removed em-dashes and filler from every
  user-facing surface (hover, panel, notifications, onboarding,
  recovery docs). The voice rule is baked into the generation prompts
  so new copy stays clean.
- The onboarding Accessibility step gained an active Continue button so
  you are never forced to hit Skip after granting the permission.
- Supervisor now announces "Supervisor updated itself" on the hover
  after a self-rebuild.
- The dispatch loop stopped spinning on the trust-prompt fix. That work
  is closed and filed as blocked-external.
- Issue #7 is fixed: bash triage no longer false-fires
  user_question_pending on a grep that mentions the category name.

## Most valuable thing remaining

Stable code signing. Every self-deploy swaps the binary and changes its
code hash, which invalidates both the Keychain access grant and the
Accessibility grant. The result is a Keychain prompt on the first key
read and an Accessibility grant that needs re-confirming. A stable
self-signed identity would make both grants persist across rebuilds.
This is the single biggest friction in the self-update story.

## Needs your attention

After each self-deploy, the new Supervisor will ask once for Keychain
access (click Always Allow) and may need the Accessibility toggle
re-confirmed. This goes away once stable signing lands.

## What the loop is doing next

The loop is proven for existing trusted sessions and will keep picking
real product work from PRODUCT-DIRECTION, Known Gaps, and open issues.
It will not propose proving the loop or bypassing the trust prompt.
