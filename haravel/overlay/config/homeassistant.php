<?php

return [

    /*
    |--------------------------------------------------------------------------
    | Home Assistant Supervisor Verification
    |--------------------------------------------------------------------------
    |
    | When enabled, the middleware will call the HA Supervisor API on each
    | request to verify the addon is running in a legitimate HA environment.
    | This guards against header spoofing if the container port were
    | accidentally exposed outside of ingress.
    |
    */

    'verify_supervisor' => env('HA_VERIFY_SUPERVISOR', true),

    /*
    |--------------------------------------------------------------------------
    | Supervisor API URL
    |--------------------------------------------------------------------------
    |
    | The internal URL used to reach the HA Supervisor API from within
    | the addon container. The SUPERVISOR_TOKEN env var is injected
    | automatically by the Supervisor at runtime.
    |
    */

    'supervisor_url' => env('HA_SUPERVISOR_URL', 'http://supervisor'),

    /*
    |--------------------------------------------------------------------------
    | User Email Domain
    |--------------------------------------------------------------------------
    |
    | HA users don't have email addresses. When creating Laravel user
    | records we synthesize one from the HA username and this domain.
    |
    */

    'user_email_domain' => env('HA_USER_EMAIL_DOMAIN', 'homeassistant.local'),

];
