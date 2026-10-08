package dev.naveax.p08probe;
import android.app.Activity;
import android.os.Bundle;
import android.util.Log;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.LinkProperties;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.Socket;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.SSLSocketFactory;
import javax.net.ssl.SSLParameters;
import javax.net.ssl.SNIHostName;
import java.util.Collections;

public final class ProbeActivity extends Activity {
    private static final String TAG = "P08Probe";
    private static String socketResult(byte[] ip, int port) {
        try (Socket socket = new Socket()) {
            socket.connect(new InetSocketAddress(InetAddress.getByAddress(ip), port), 2500);
            return "CONNECTED";
        } catch (Exception e) {
            return "BLOCKED_" + e.getClass().getSimpleName();
        }
    }

    // Unlike a TCP connect() ACK, a completed TLS handshake proves an
    // application-layer stream reached a TLS endpoint beyond local tun2socks.
    private static String tlsResult(byte[] ip, String hostname) {
        try (SSLSocket socket = (SSLSocket)SSLSocketFactory.getDefault().createSocket()) {
            socket.connect(new InetSocketAddress(InetAddress.getByAddress(ip), 443), 2500);
            socket.setSoTimeout(4000);
            SSLParameters parameters = socket.getSSLParameters();
            parameters.setEndpointIdentificationAlgorithm("HTTPS");
            parameters.setServerNames(Collections.singletonList(new SNIHostName(hostname)));
            socket.setSSLParameters(parameters);
            socket.startHandshake();
            return "HANDSHAKE_OK";
        } catch (Exception e) {
            return "FAILED_" + e.getClass().getSimpleName();
        }
    }

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        String runId = getIntent().getStringExtra("RUN_ID");
        if (runId == null || !runId.matches("[0-9a-f]{32}")) runId = "manual";
        final String stamp = "RUN=" + runId + " ";
        new Thread(() -> {
            try {
                ConnectivityManager cm = (ConnectivityManager)getSystemService(CONNECTIVITY_SERVICE);
                Network active = cm.getActiveNetwork();
                NetworkCapabilities caps = active == null ? null : cm.getNetworkCapabilities(active);
                LinkProperties lp = active == null ? null : cm.getLinkProperties(active);
                Log.i(TAG, stamp + "ACTIVE_NETWORK=" + (active == null ? "NONE" : "PRESENT")
                        + " VPN=" + (caps != null && caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN))
                        + " DNS_COUNT=" + (lp == null ? -1 : lp.getDnsServers().size()));
                Log.i(TAG, stamp + "IPV4_TCP=" + socketResult(new byte[]{1,1,1,1},443));
                Log.i(TAG, stamp + "IPV4_OTHER_TCP=" + socketResult(new byte[]{8,8,8,8},443));
                Log.i(TAG, stamp + "IPV4_TLS_END_TO_END=" + tlsResult(new byte[]{1,1,1,1}, "one.one.one.one"));
                Log.i(TAG, stamp + "IPV6_TCP=" + socketResult(new byte[]{0x26,0x06,0x47,0x00,0x47,0x00,0,0,0,0,0,0,0,0,0x11,0x11},443));
                try {
                    InetAddress[] addresses=InetAddress.getAllByName("example.com");
                    Log.i(TAG, stamp + "DNS_LOOKUP=RESOLVED COUNT=" + addresses.length);
                } catch (Exception e) {
                    Log.i(TAG, stamp + "DNS_LOOKUP=BLOCKED_" + e.getClass().getSimpleName());
                }
                Log.i(TAG, stamp + "PROBE_DONE");
            } catch (Throwable e) {
                Log.e(TAG,stamp + "PROBE_FAILED="+e.getClass().getSimpleName());
            } finally { runOnUiThread(this::finish); }
        }).start();
    }
}
