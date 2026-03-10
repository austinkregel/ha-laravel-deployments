<?php

namespace App\Http\Middleware;

use App\Models\User;
use Closure;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Str;
use Symfony\Component\HttpFoundation\Response;

class HomeAssistantAuth
{
    public function handle(Request $request, Closure $next): Response
    {
        $haUserId = $request->header('X-Remote-User-ID');
        $haUserName = $request->header('X-Remote-User-Name');
        $haDisplayName = $request->header('X-Remote-User-Display-Name');

        if (! $haUserId) {
            abort(401, 'No Home Assistant user identity provided.');
        }

        if (config('homeassistant.verify_supervisor')) {
            $this->verifySupervisor();
        }

        $domain = config('homeassistant.user_email_domain', 'homeassistant.local');

        $user = User::firstOrCreate(
            ['email' => $haUserName.'@'.$domain],
            [
                'name' => $haDisplayName ?? $haUserName ?? 'HA User',
                'password' => bcrypt(Str::random(64)),
            ]
        );

        Auth::login($user);

        return $next($request);
    }

    protected function verifySupervisor(): void
    {
        $token = env('SUPERVISOR_TOKEN');

        if (empty($token)) {
            Log::warning('SUPERVISOR_TOKEN is not set — skipping HA verification.');

            return;
        }

        $url = config('homeassistant.supervisor_url', 'http://supervisor');

        try {
            $response = Http::withHeaders([
                'Authorization' => 'Bearer '.$token,
            ])->timeout(5)->get($url.'/core/api/config');

            if (! $response->ok()) {
                abort(401, 'Failed to verify addon context with Home Assistant Supervisor.');
            }
        } catch (\Exception $e) {
            Log::error('HA Supervisor verification failed: '.$e->getMessage());
            abort(401, 'Failed to verify addon context with Home Assistant Supervisor.');
        }
    }
}
