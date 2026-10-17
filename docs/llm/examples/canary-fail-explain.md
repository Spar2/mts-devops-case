*   **Failed Check:** The smoke test failed with HTTP 401 errors for login and GET/POST requests, specifically failing the expected session cookie `dts_session`.
*   **Pipeline Action:** The pipeline automatically rolled back the canary by setting its weight to 0, uninstalling the release, and running `smoke stable release sensor` to restore traffic.
*   **Stable Traffic Impact:** No stable traffic was affected; the stable release `sensor` continued to serve traffic with all checks passing (HTTP 200, valid cookies).
*   **Next Steps:** Investigate why the canary secret `sensor-secrets-wrong` was created and why the login logic expects a session cookie that the canary instance does not possess.
*   **Concrete Values:** The rollback triggered by `FAIL login: HTTP 401, expected 200 and cookie dts_session` and the final status `PASS login cookie dts_session` for the stable release.
