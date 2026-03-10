<?php

namespace App\Http\Middleware;

use Illuminate\Foundation\Http\Middleware\VerifyCsrfToken as BaseVerifier;

class TrustIngress extends BaseVerifier
{
    /**
     * When the request arrives through HA ingress (indicated by the
     * X-Remote-User-ID header), CSRF verification is skipped. The
     * Supervisor proxy manages session security for ingress requests.
     */
    protected function tokensMatch($request): bool
    {
        if ($request->header('X-Remote-User-ID')) {
            return true;
        }

        return parent::tokensMatch($request);
    }
}
