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
import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.Base64;

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
    private static String tlsResult(String hostname) {
        // Passing the hostname to createSocket is essential. A TLS SNI value
        // alone does not reliably bind HTTPS certificate verification to it.
        try (SSLSocket socket = connectVerifiedTls(hostname, 443)) {
            return "HANDSHAKE_OK";
        } catch (Exception e) {
            return "FAILED_" + e.getClass().getSimpleName();
        }
    }

    private static final byte[] DNS_IP = new byte[]{1,1,1,1};
    private static final SecureRandom RANDOM = new SecureRandom();

    private static byte[] dnsQuery(int qtype) {
        int id = RANDOM.nextInt(65536);
        return new byte[]{
            (byte)(id >>> 8), (byte)id, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0,
            7, 'e','x','a','m','p','l','e', 3, 'c','o','m', 0,
            (byte)(qtype >>> 8), (byte)qtype, 0, 1
        };
    }

    private static boolean validDnsResponse(byte[] query, byte[] reply) {
        return DnsEvidence.matchesExactQuestion(query, reply);
    }

    private static byte[] readFully(InputStream stream, int length) throws Exception {
        if (length < 1 || length > 4096) throw new IllegalStateException("InvalidDnsLength");
        byte[] body = new byte[length];
        int offset = 0;
        while (offset < length) {
            int n = stream.read(body, offset, length - offset);
            if (n < 0) throw new IllegalStateException("IncompleteDnsResponse");
            offset += n;
        }
        return body;
    }

    private static String dnsUdpResult(int qtype) {
        byte[] query = dnsQuery(qtype);
        try (DatagramSocket socket = new DatagramSocket()) {
            socket.setSoTimeout(2800);
            socket.connect(new InetSocketAddress(InetAddress.getByAddress(DNS_IP), 53));
            socket.send(new DatagramPacket(query, query.length));
            byte[] buffer = new byte[4096];
            DatagramPacket packet = new DatagramPacket(buffer, buffer.length);
            socket.receive(packet);
            byte[] reply = new byte[packet.getLength()];
            System.arraycopy(packet.getData(), packet.getOffset(), reply, 0, reply.length);
            return validDnsResponse(query, reply) ? "RESPONSE_VERIFIED" : "UNVERIFIED_REPLY";
        } catch (Exception e) {
            return "NO_VERIFIED_RESPONSE_" + e.getClass().getSimpleName();
        }
    }

    private static String dnsTcpResult() {
        byte[] query = dnsQuery(1);
        try (Socket socket = new Socket()) {
            socket.connect(new InetSocketAddress(InetAddress.getByAddress(DNS_IP), 53), 2500);
            socket.setSoTimeout(3000);
            OutputStream out = socket.getOutputStream();
            out.write(new byte[]{(byte)(query.length >>> 8), (byte)query.length});
            out.write(query);
            out.flush();
            InputStream in = socket.getInputStream();
            int high = in.read(), low = in.read();
            if (high < 0 || low < 0) throw new IllegalStateException("MissingDnsFrame");
            byte[] reply = readFully(in, (high << 8) | low);
            return validDnsResponse(query, reply) ? "RESPONSE_VERIFIED" : "UNVERIFIED_REPLY";
        } catch (Exception e) {
            return "NO_VERIFIED_RESPONSE_" + e.getClass().getSimpleName();
        }
    }

    private static SSLSocket connectVerifiedTls(String host, int port) throws Exception {
        Socket raw = new Socket();
        try {
            raw.connect(new InetSocketAddress(InetAddress.getByAddress(DNS_IP), port), 2500);
            SSLSocketFactory factory = (SSLSocketFactory)SSLSocketFactory.getDefault();
            SSLSocket socket = (SSLSocket)factory.createSocket(raw, host, port, true);
            socket.setSoTimeout(3000);
            SSLParameters params = socket.getSSLParameters();
            // Passing the host to createSocket establishes the verified TLS
            // peer name. SNI alone is NOT hostname verification.
            params.setEndpointIdentificationAlgorithm("HTTPS");
            params.setServerNames(Collections.singletonList(new SNIHostName(host)));
            socket.setSSLParameters(params);
            socket.startHandshake();
            return socket;
        } catch (Exception e) {
            try { raw.close(); } catch (Exception ignored) {}
            throw e;
        }
    }

    private static String dotResult() {
        byte[] query = dnsQuery(1);
        try (SSLSocket socket = connectVerifiedTls("cloudflare-dns.com", 853)) {
            OutputStream out = socket.getOutputStream();
            out.write(new byte[]{(byte)(query.length >>> 8), (byte)query.length});
            out.write(query);
            out.flush();
            InputStream in = socket.getInputStream();
            int high = in.read(), low = in.read();
            if (high < 0 || low < 0) throw new IllegalStateException("MissingDotFrame");
            byte[] reply = readFully(in, (high << 8) | low);
            return validDnsResponse(query, reply) ? "RESPONSE_VERIFIED" : "UNVERIFIED_REPLY";
        } catch (Exception e) {
            return "NO_VERIFIED_RESPONSE_" + e.getClass().getSimpleName();
        }
    }

    private static String httpLine(InputStream input) throws Exception {
        ByteArrayOutputStream line = new ByteArrayOutputStream();
        while (line.size() < 1024) {
            int ch = input.read();
            if (ch < 0) throw new IllegalStateException("IncompleteHttpResponse");
            if (ch == '\n') {
                byte[] raw = line.toByteArray();
                int len = raw.length;
                if (len > 0 && raw[len - 1] == '\r') len--;
                return new String(raw, 0, len, StandardCharsets.US_ASCII);
            }
            line.write(ch);
        }
        throw new IllegalStateException("HttpHeaderTooLong");
    }

    private static String dohResult() {
        byte[] query = dnsQuery(1);
        try (SSLSocket socket = connectVerifiedTls("cloudflare-dns.com", 443)) {
            String encoded = Base64.getUrlEncoder().withoutPadding().encodeToString(query);
            String request = "GET /dns-query?dns=" + encoded + " HTTP/1.1\r\n" +
                "Host: cloudflare-dns.com\r\nAccept: application/dns-message\r\n" +
                "Connection: close\r\n\r\n";
            OutputStream out = socket.getOutputStream();
            out.write(request.getBytes(StandardCharsets.US_ASCII));
            out.flush();
            InputStream in = new BufferedInputStream(socket.getInputStream());
            String status = httpLine(in);
            if (!status.startsWith("HTTP/1.1 200 ") && !status.equals("HTTP/1.1 200"))
                return "HTTP_NOT_200";
            boolean correctMime = false, chunked = false;
            for (int lineCount = 0; lineCount < 40; lineCount++) {
                String line = httpLine(in);
                if (line.isEmpty()) break;
                String lower = line.toLowerCase(java.util.Locale.ROOT);
                if (lower.startsWith("content-type:") &&
                        lower.contains("application/dns-message")) correctMime = true;
                if (lower.startsWith("transfer-encoding:") &&
                        lower.contains("chunked")) chunked = true;
                if (lineCount == 39) throw new IllegalStateException("TooManyHeaders");
            }
            if (!correctMime) return "HTTP_WRONG_MIME";
            if (chunked) {
                String chunkHeader = httpLine(in).split(";", 2)[0];
                int size = Integer.parseInt(chunkHeader.trim(), 16);
                byte[] reply = readFully(in, size);
                return validDnsResponse(query, reply) ? "RESPONSE_VERIFIED" : "UNVERIFIED_REPLY";
            }
            // A 12-byte response header is not evidence of the exact DNS
            // question. Require the complete query-sized prefix at minimum.
            byte[] reply = readFully(in, query.length);
            return validDnsResponse(query, reply) ? "RESPONSE_VERIFIED" : "UNVERIFIED_REPLY";
        } catch (Exception e) {
            return "NO_VERIFIED_RESPONSE_" + e.getClass().getSimpleName();
        }
    }

    // Hold the OS network handle only in memory. Never log a handle, SSID,
    // address, resolver IP or actual lookup. An endpoint response is otherwise
    // easy to attribute to the WRONG VPN epoch after a handover.
    private static final class NetworkSnapshot {
        final Network handle;
        final boolean vpn;
        final int dnsCount;
        NetworkSnapshot(Network handle, boolean vpn, int dnsCount) {
            this.handle = handle;
            this.vpn = vpn;
            this.dnsCount = dnsCount;
        }
        boolean sameAs(NetworkSnapshot other) {
            boolean sameHandle = handle == null ? other.handle == null :
                handle.equals(other.handle);
            return sameHandle && vpn == other.vpn && dnsCount == other.dnsCount;
        }
        String status() {
            return handle == null ? "NONE" : "PRESENT";
        }
    }

    private static NetworkSnapshot snapshot(ConnectivityManager cm) {
        Network handle = cm.getActiveNetwork();
        NetworkCapabilities caps = handle == null ? null : cm.getNetworkCapabilities(handle);
        LinkProperties lp = handle == null ? null : cm.getLinkProperties(handle);
        return new NetworkSnapshot(handle,
                caps != null && caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN),
                lp == null ? -1 : lp.getDnsServers().size());
    }

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        String runId = getIntent().getStringExtra("RUN_ID");
        if (runId == null || !runId.matches("[0-9a-f]{32}")) runId = "manual";
        final String stamp = "RUN=" + runId + " ";
        new Thread(() -> {
            try {
                ConnectivityManager cm = (ConnectivityManager)getSystemService(CONNECTIVITY_SERVICE);
                NetworkSnapshot first = snapshot(cm);
                boolean networkStable = true;
                Log.i(TAG, stamp + "ACTIVE_NETWORK=" + first.status()
                        + " VPN=" + first.vpn + " DNS_COUNT=" + first.dnsCount);
                Log.i(TAG, stamp + "IPV4_TCP=" + socketResult(new byte[]{1,1,1,1},443));
                networkStable &= first.sameAs(snapshot(cm));
                Log.i(TAG, stamp + "IPV4_OTHER_TCP=" + socketResult(new byte[]{8,8,8,8},443));
                networkStable &= first.sameAs(snapshot(cm));
                Log.i(TAG, stamp + "IPV4_TLS_END_TO_END=" + tlsResult("one.one.one.one"));
                networkStable &= first.sameAs(snapshot(cm));
                Log.i(TAG, stamp + "DIRECT_DNS_A_UDP53=" + dnsUdpResult(1));
                networkStable &= first.sameAs(snapshot(cm));
                Log.i(TAG, stamp + "DIRECT_DNS_AAAA_UDP53=" + dnsUdpResult(28));
                networkStable &= first.sameAs(snapshot(cm));
                Log.i(TAG, stamp + "DIRECT_DNS_A_TCP53=" + dnsTcpResult());
                networkStable &= first.sameAs(snapshot(cm));
                Log.i(TAG, stamp + "DOT_DNS_A_TLS853=" + dotResult());
                networkStable &= first.sameAs(snapshot(cm));
                Log.i(TAG, stamp + "DOH_DNS_A_HTTPS443=" + dohResult());
                networkStable &= first.sameAs(snapshot(cm));
                Log.i(TAG, stamp + "IPV6_TCP=" + socketResult(new byte[]{0x26,0x06,0x47,0x00,0x47,0x00,0,0,0,0,0,0,0,0,0x11,0x11},443));
                networkStable &= first.sameAs(snapshot(cm));
                try {
                    InetAddress[] addresses=InetAddress.getAllByName("example.com");
                    Log.i(TAG, stamp + "DNS_LOOKUP=RESOLVED COUNT=" + addresses.length);
                } catch (Exception e) {
                    Log.i(TAG, stamp + "DNS_LOOKUP=BLOCKED_" + e.getClass().getSimpleName());
                }
                networkStable &= first.sameAs(snapshot(cm));
                NetworkSnapshot end = snapshot(cm);
                networkStable &= first.sameAs(end);
                Log.i(TAG, stamp + "NETWORK_END=" + end.status()
                        + " VPN=" + end.vpn + " DNS_COUNT=" + end.dnsCount);
                Log.i(TAG, stamp + "NETWORK_STABLE=" + networkStable);
                Log.i(TAG, stamp + "PROBE_DONE");
            } catch (Throwable e) {
                Log.e(TAG,stamp + "PROBE_FAILED="+e.getClass().getSimpleName());
            } finally { runOnUiThread(this::finish); }
        }).start();
    }
}
