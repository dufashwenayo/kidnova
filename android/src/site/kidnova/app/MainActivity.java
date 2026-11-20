package site.kidnova.app;

import android.Manifest;
import android.app.Activity;
import android.app.DownloadManager;
import android.content.ActivityNotFoundException;
import android.content.ContentValues;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.net.ConnectivityManager;
import android.net.NetworkInfo;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.os.Handler;
import android.os.Looper;
import android.provider.MediaStore;
import android.util.Base64;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.webkit.CookieManager;
import android.webkit.JavascriptInterface;
import android.webkit.URLUtil;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;
import android.widget.Toast;

import java.io.File;
import java.io.FileOutputStream;
import java.io.OutputStream;

/**
 * KIDNOVA for Android: the kidnova.site web app in a full-screen WebView,
 * with phone/SMS/WhatsApp links, file uploads and PDF downloads handled natively.
 */
public class MainActivity extends Activity {
    private static final String HOME = "https://kidnova.site/";
    private static final String HOST = "kidnova.site";
    private static final int REQ_FILE = 41;
    private static final int REQ_STORAGE = 42;
    private static final int REQ_NOTIFY = 43;

    private WebView web;
    private ProgressBar bar;
    private LinearLayout offline;
    private ValueCallback<Uri[]> fileCallback;
    private String pendingB64, pendingMime, pendingName;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.parseColor("#F3F5F9"));

        web = new WebView(this);
        root.addView(web, new FrameLayout.LayoutParams(-1, -1));

        bar = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        bar.setMax(100);
        bar.setIndeterminate(false);
        FrameLayout.LayoutParams bp = new FrameLayout.LayoutParams(-1, dp(3), Gravity.TOP);
        root.addView(bar, bp);

        offline = buildOfflineView();
        offline.setVisibility(View.GONE);
        root.addView(offline, new FrameLayout.LayoutParams(-1, -1));

        setContentView(root);
        setupWebView();
        Reminders.ensureChannel(this);
        Reminders.schedule(this);

        if (state != null && web.restoreState(state) != null) return;
        Uri data = getIntent() != null ? getIntent().getData() : null;
        web.loadUrl(data != null && isOwnUrl(data) ? data.toString() : HOME);
    }

    private void setupWebView() {
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setDatabaseEnabled(true);
        s.setLoadWithOverviewMode(true);
        s.setUseWideViewPort(true);
        s.setBuiltInZoomControls(false);
        s.setSupportMultipleWindows(false);
        s.setJavaScriptCanOpenWindowsAutomatically(false);
        s.setMediaPlaybackRequiresUserGesture(true);
        s.setAllowFileAccess(false);
        s.setCacheMode(WebSettings.LOAD_DEFAULT);
        s.setUserAgentString(s.getUserAgentString() + " KidnovaApp/" + BuildInfo.VERSION + " (Android)");

        CookieManager.getInstance().setAcceptCookie(true);
        CookieManager.getInstance().setAcceptThirdPartyCookies(web, true);
        web.addJavascriptInterface(new Bridge(this), "KidnovaApp");

        web.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest req) {
                return handleUrl(req.getUrl());
            }

            @Override
            public void onPageFinished(WebView view, String url) {
                CookieManager.getInstance().flush();
            }

            @Override
            public void onReceivedError(WebView view, WebResourceRequest req, WebResourceError err) {
                if (req.isForMainFrame()) showOffline(true);
            }
        });

        web.setWebChromeClient(new WebChromeClient() {
            @Override
            public void onProgressChanged(WebView view, int p) {
                bar.setProgress(p);
                bar.setVisibility(p >= 100 ? View.GONE : View.VISIBLE);
            }

            @Override
            public boolean onShowFileChooser(WebView view, ValueCallback<Uri[]> cb, FileChooserParams params) {
                if (fileCallback != null) fileCallback.onReceiveValue(null);
                fileCallback = cb;
                try {
                    startActivityForResult(params.createIntent(), REQ_FILE);
                } catch (ActivityNotFoundException e) {
                    fileCallback = null;
                    toast("No app found to choose a file.");
                    return false;
                }
                return true;
            }
        });

        web.setDownloadListener((url, ua, disposition, mime, length) -> {
            if (url.startsWith("blob:") || url.startsWith("data:")) {
                // Files made in the page (backups): read them in JavaScript and hand them over.
                String js = "(async()=>{try{const r=await fetch('" + url.replace("'", "\\'") + "');const b=await r.blob();"
                        + "const f=new FileReader();f.onload=()=>KidnovaApp.saveFile(String(f.result).split(',')[1],b.type||'" + (mime == null ? "" : mime) + "','');"
                        + "f.readAsDataURL(b);}catch(e){KidnovaApp.toast('Could not download this file.')}})()";
                web.evaluateJavascript(js, null);
                return;
            }
            try {
                String name = URLUtil.guessFileName(url, disposition, mime);
                DownloadManager.Request r = new DownloadManager.Request(Uri.parse(url));
                r.setMimeType(mime);
                r.addRequestHeader("User-Agent", ua);
                r.setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED);
                r.setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, name);
                ((DownloadManager) getSystemService(Context.DOWNLOAD_SERVICE)).enqueue(r);
                toast("Downloading " + name + "…");
            } catch (Exception e) {
                openExternal(Uri.parse(url));
            }
        });
    }

    /** Keep kidnova.site inside the app; send calls, SMS, WhatsApp, email and other sites to the phone's apps. */
    private boolean handleUrl(Uri uri) {
        if (isOwnUrl(uri)) return false;
        openExternal(uri);
        return true;
    }

    private boolean isOwnUrl(Uri uri) {
        String scheme = uri.getScheme(), host = uri.getHost();
        return "https".equals(scheme) && host != null && (host.equals(HOST) || host.endsWith("." + HOST));
    }

    private void openExternal(Uri uri) {
        try {
            Intent i;
            if ("intent".equals(uri.getScheme())) {
                i = Intent.parseUri(uri.toString(), Intent.URI_INTENT_SCHEME);
                i.addCategory(Intent.CATEGORY_BROWSABLE);
                i.setComponent(null);
                i.setSelector(null);
            } else if ("tel".equals(uri.getScheme())) {
                i = new Intent(Intent.ACTION_DIAL, uri);
            } else if ("sms".equals(uri.getScheme()) || "smsto".equals(uri.getScheme())) {
                i = new Intent(Intent.ACTION_SENDTO, uri);
                String body = uri.getQueryParameter("body");
                if (body != null) {
                    String ssp = uri.getSchemeSpecificPart();
                    int q = ssp.indexOf('?');
                    i.setData(Uri.parse("smsto:" + (q >= 0 ? ssp.substring(0, q) : ssp)));
                    i.putExtra("sms_body", body);
                }
            } else {
                i = new Intent(Intent.ACTION_VIEW, uri);
            }
            startActivity(i);
        } catch (ActivityNotFoundException e) {
            if ("whatsapp".equals(uri.getScheme())) toast("WhatsApp is not installed on this phone.");
            else toast("No app on this phone can open this link.");
        } catch (Exception e) {
            toast("This link could not be opened.");
        }
    }

    private LinearLayout buildOfflineView() {
        LinearLayout v = new LinearLayout(this);
        v.setOrientation(LinearLayout.VERTICAL);
        v.setGravity(Gravity.CENTER);
        v.setPadding(dp(32), dp(32), dp(32), dp(32));
        v.setBackgroundColor(Color.parseColor("#F3F5F9"));
        v.setClickable(true);

        TextView emoji = new TextView(this);
        emoji.setText("📶");
        emoji.setTextSize(48);
        emoji.setGravity(Gravity.CENTER);
        v.addView(emoji);

        TextView title = new TextView(this);
        title.setText("No internet connection");
        title.setTextSize(20);
        title.setTextColor(Color.parseColor("#14305C"));
        title.setGravity(Gravity.CENTER);
        title.setPadding(0, dp(12), 0, dp(6));
        title.setTypeface(null, android.graphics.Typeface.BOLD);
        v.addView(title);

        TextView msg = new TextView(this);
        msg.setText("KIDNOVA needs the internet to save attendance and assessments. Turn on mobile data or Wi-Fi, then try again.\n\nSupport: +250 783 568 044");
        msg.setTextSize(15);
        msg.setTextColor(Color.parseColor("#5D6B7F"));
        msg.setGravity(Gravity.CENTER);
        v.addView(msg);

        Button retry = new Button(this);
        retry.setText("Try again");
        retry.setAllCaps(false);
        retry.setTextColor(Color.WHITE);
        retry.setBackgroundColor(Color.parseColor("#0B6CB5"));
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dp(48));
        lp.topMargin = dp(20);
        retry.setPadding(dp(28), 0, dp(28), 0);
        retry.setOnClickListener(x -> {
            showOffline(false);
            String u = web.getUrl();
            if (u == null || !u.startsWith("https://")) web.loadUrl(HOME); else web.reload();
        });
        v.addView(retry, lp);
        return v;
    }

    private void showOffline(boolean on) {
        offline.setVisibility(on ? View.VISIBLE : View.GONE);
    }

    @SuppressWarnings("deprecation")
    private boolean isOnline() {
        ConnectivityManager cm = (ConnectivityManager) getSystemService(Context.CONNECTIVITY_SERVICE);
        NetworkInfo ni = cm == null ? null : cm.getActiveNetworkInfo();
        return ni != null && ni.isConnected();
    }

    /** Called from the web page. */
    static final class Bridge {
        private final MainActivity act;
        Bridge(MainActivity act) { this.act = act; }

        @JavascriptInterface
        public void saveFile(String base64, String mime, String name) {
            new Handler(Looper.getMainLooper()).post(() -> act.saveDownload(base64, mime, name));
        }

        @JavascriptInterface
        public void toast(String msg) {
            new Handler(Looper.getMainLooper()).post(() -> act.toast(msg));
        }

        @JavascriptInterface
        public String version() {
            return BuildInfo.VERSION;
        }

        /** The page reports today's attendance state for this teacher (JSON). */
        @JavascriptInterface
        public void setAttendance(String json) {
            new Handler(Looper.getMainLooper()).post(() -> act.onAttendanceState(json));
        }

        @JavascriptInterface
        public String getReminders() {
            try {
                org.json.JSONObject o = new org.json.JSONObject();
                o.put("on", Reminders.enabled(act));
                o.put("morning", Reminders.morning(act));
                o.put("followup", Reminders.followUp(act));
                o.put("allowed", act.notificationsAllowed());
                return o.toString();
            } catch (Exception e) { return "{}"; }
        }

        @JavascriptInterface
        public void setReminders(boolean on, String morning, String followUp) {
            new Handler(Looper.getMainLooper()).post(() -> act.onReminderSettings(on, morning, followUp));
        }

        @JavascriptInterface
        public void testReminder() {
            new Handler(Looper.getMainLooper()).post(() -> {
                act.askNotificationPermission();
                Reminders.notify(act, "KIDNOVA reminders are on", "You will be reminded at " + Reminders.morning(act) + " when a register is not saved yet.");
            });
        }
    }

    void onAttendanceState(String json) {
        try {
            org.json.JSONObject o = new org.json.JSONObject(json);
            boolean teacher = o.optBoolean("teacher", false);
            android.content.SharedPreferences.Editor e = Reminders.prefs(this).edit().putBoolean("teacher", teacher);
            if (teacher) e.putString("state", json); else e.remove("state");
            e.apply();
            if (teacher) {
                org.json.JSONArray m = o.optJSONArray("missing");
                if (Reminders.today().equals(o.optString("date")) && (m == null || m.length() == 0)) Reminders.clear(this);
                if (Reminders.enabled(this) && !Reminders.prefs(this).getBoolean("asked", false)) {
                    Reminders.prefs(this).edit().putBoolean("asked", true).apply();
                    askNotificationPermission();
                }
            } else {
                Reminders.clear(this);
            }
            Reminders.schedule(this);
        } catch (Exception ignored) { }
    }

    void onReminderSettings(boolean on, String morning, String followUp) {
        Reminders.prefs(this).edit().putBoolean("on", on)
                .putString("morning", morning == null || morning.isEmpty() ? "08:30" : morning)
                .putString("followup", followUp == null ? "" : followUp).apply();
        if (on) askNotificationPermission(); else Reminders.clear(this);
        Reminders.schedule(this);
    }

    boolean notificationsAllowed() {
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return false;
        android.app.NotificationManager nm = (android.app.NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        return nm == null || nm.areNotificationsEnabled();
    }

    void askNotificationPermission() {
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, REQ_NOTIFY);
        }
    }

    private void saveDownload(String base64, String mime, String name) {
        if (mime == null || mime.isEmpty()) mime = "application/octet-stream";
        if (name == null || name.isEmpty()) {
            String ext = mime.contains("pdf") ? ".pdf" : mime.contains("json") ? ".json" : "";
            name = "kidnova-" + System.currentTimeMillis() + ext;
        }
        if (Build.VERSION.SDK_INT < 29 && checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED) {
            pendingB64 = base64; pendingMime = mime; pendingName = name;
            requestPermissions(new String[]{Manifest.permission.WRITE_EXTERNAL_STORAGE}, REQ_STORAGE);
            return;
        }
        try {
            byte[] bytes = Base64.decode(base64, Base64.DEFAULT);
            Uri openUri = null;
            if (Build.VERSION.SDK_INT >= 29) {
                ContentValues cv = new ContentValues();
                cv.put(MediaStore.MediaColumns.DISPLAY_NAME, name);
                cv.put(MediaStore.MediaColumns.MIME_TYPE, mime);
                cv.put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS);
                Uri uri = getContentResolver().insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, cv);
                if (uri == null) throw new Exception("no uri");
                try (OutputStream out = getContentResolver().openOutputStream(uri)) { out.write(bytes); }
                openUri = uri;
            } else {
                File dir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS);
                dir.mkdirs();
                File f = new File(dir, name);
                try (FileOutputStream out = new FileOutputStream(f)) { out.write(bytes); }
            }
            toast("Saved to Downloads: " + name);
            if (openUri != null) {
                Intent view = new Intent(Intent.ACTION_VIEW);
                view.setDataAndType(openUri, mime);
                view.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                try { startActivity(view); } catch (ActivityNotFoundException ignored) { }
            }
        } catch (Exception e) {
            toast("The file could not be saved.");
        }
    }

    @Override
    public void onRequestPermissionsResult(int code, String[] perms, int[] res) {
        if (code == REQ_NOTIFY) {
            web.evaluateJavascript("window.onKidnovaReminders&&window.onKidnovaReminders()", null);
            return;
        }
        if (code == REQ_STORAGE && pendingB64 != null) {
            String b = pendingB64, m = pendingMime, n = pendingName;
            pendingB64 = null;
            if (res.length > 0 && res[0] == PackageManager.PERMISSION_GRANTED) saveDownload(b, m, n);
            else toast("Allow storage to save files to Downloads.");
        }
    }

    @Override
    protected void onActivityResult(int code, int result, Intent data) {
        if (code == REQ_FILE && fileCallback != null) {
            fileCallback.onReceiveValue(WebChromeClient.FileChooserParams.parseResult(result, data));
            fileCallback = null;
            return;
        }
        super.onActivityResult(code, result, data);
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        Uri data = intent.getData();
        if (data != null && isOwnUrl(data)) web.loadUrl(data.toString());
    }

    @Override
    public void onBackPressed() {
        if (offline.getVisibility() == View.VISIBLE && web.canGoBack()) { showOffline(false); web.goBack(); return; }
        if (web.canGoBack()) web.goBack();
        else super.onBackPressed();
    }

    @Override
    protected void onResume() {
        super.onResume();
        web.onResume();
        web.evaluateJavascript("window.onKidnovaReminders&&window.onKidnovaReminders()", null);
        if (offline.getVisibility() == View.VISIBLE && isOnline()) { showOffline(false); web.reload(); }
    }

    @Override
    protected void onPause() {
        web.onPause();
        CookieManager.getInstance().flush();
        super.onPause();
    }

    @Override
    protected void onSaveInstanceState(Bundle out) {
        super.onSaveInstanceState(out);
        web.saveState(out);
    }

    private void toast(String msg) {
        Toast.makeText(this, msg, Toast.LENGTH_LONG).show();
    }

    private int dp(int v) {
        return Math.round(v * getResources().getDisplayMetrics().density);
    }
}
