<?php

namespace App\Providers;

use App\Http\Middleware\HomeAssistantAuth;
use App\Http\Middleware\TrustIngress;
use Illuminate\Contracts\Http\Kernel;
use Illuminate\Foundation\Http\Middleware\VerifyCsrfToken;
use Illuminate\Support\Facades\Route;
use Illuminate\Support\Facades\URL;
use Illuminate\Support\ServiceProvider;

class HomeAssistantServiceProvider extends ServiceProvider
{
    public function boot(): void
    {
        $this->registerMiddleware();
        $this->disableNativeAuth();
        $this->fixIngressUrls();
    }

    /**
     * Prepend the HA auth middleware to the web group and swap
     * the CSRF verifier with our ingress-aware version.
     */
    protected function registerMiddleware(): void
    {
        $kernel = $this->app->make(Kernel::class);

        $kernel->prependMiddlewareToGroup('web', HomeAssistantAuth::class);

        // Replace VerifyCsrfToken with TrustIngress in the web group.
        // The swap approach works across Laravel 8-12.
        $this->app->bind(VerifyCsrfToken::class, TrustIngress::class);
    }

    /**
     * Redirect native login/register routes to the app root since
     * authentication is fully handled by Home Assistant.
     */
    protected function disableNativeAuth(): void
    {
        // Override Fortify views if Fortify is installed
        if (class_exists(\Laravel\Fortify\Fortify::class)) {
            \Laravel\Fortify\Fortify::loginView(fn () => redirect('/'));
            \Laravel\Fortify\Fortify::registerView(fn () => redirect('/'));
        }

        // Catch-all redirects for common auth routes
        Route::middleware('web')->group(function () {
            foreach (['/login', '/register', '/forgot-password'] as $path) {
                Route::get($path, fn () => redirect('/'))->name('ha-laravel.redirect.'.ltrim($path, '/'));
            }
        });
    }

    /**
     * When accessed through HA ingress, the app sits behind a
     * proxy path like /api/hassio_ingress/{token}/. The Supervisor
     * sends the base path in X-Ingress-Path so we can fix URL
     * generation.
     */
    protected function fixIngressUrls(): void
    {
        $this->app->booted(function () {
            $ingressPath = request()->header('X-Ingress-Path');

            if ($ingressPath) {
                URL::forceRootUrl($ingressPath);
                config(['app.url' => $ingressPath]);
            }
        });
    }
}
