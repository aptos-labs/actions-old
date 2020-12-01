> **Note to readers:** On December 1, 2020, the Libra Association was renamed to Diem Association. The project repos are in the process of being migrated. All projects will remain available for use here until the migration to a new GitHub Organization is complete.

# github actions

These actions are custom for Libra Core workflows. Some of these actions are
hyperjump-powered, which means they allow specific, benign capabilities even
from forked repositories. Hyperjump actions consist of the action workflows
should use (ex. `comment`) and the backend hyperjump part that triggers on
`repository_dispatch` events (ex. `hyperjump-comment`).
