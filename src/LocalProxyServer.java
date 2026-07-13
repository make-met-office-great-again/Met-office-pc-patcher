package uk.gov.metoffice.weather.android.proxy;

import android.util.Log;
import org.json.JSONArray;
import org.json.JSONObject;

import java.io.*;
import java.net.*;
import java.text.SimpleDateFormat;
import java.util.*;

public class LocalProxyServer {
    private static final String TAG = "LocalProxyServer";
    private static final int PORT = 18080;
    private static final String API_KEY = "PUT_API_KEY_IN_API_TXT";
    private static ServerSocket serverSocket;
    private static boolean running = false;

    // Cache parameters: 30 minutes Time-To-Live (TTL)
    private static final long CACHE_TTL_MS = 30 * 60 * 1000; 

    private static File getCacheDir() {
        try {
            Class<?> activityThreadClass = Class.forName("android.app.ActivityThread");
            Object application = activityThreadClass.getMethod("currentApplication").invoke(null);
            if (application instanceof android.app.Application) {
                File cacheDir = ((android.app.Application) application).getCacheDir();
                if (cacheDir != null) {
                    return cacheDir;
                }
            }
        } catch (Exception e) {
            Log.w(TAG, "Unable to resolve application cache dir via ActivityThread", e);
        }

        File fallback = new File("/data/data/uk.gov.metoffice.weather.android/cache");
        fallback.mkdirs();
        return fallback;
    }

    public static synchronized void start() {
        if (running) return;
        running = true;
        new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    serverSocket = new ServerSocket(PORT, 50, InetAddress.getByName("127.0.0.1"));
                    Log.d(TAG, "LocalProxyServer started on port " + PORT);
                    while (running) {
                        Socket socket = serverSocket.accept();
                        handleConnection(socket);
                    }
                } catch (Exception e) {
                    Log.e(TAG, "Server error", e);
                }
            }
        }).start();
    }

    private static void handleConnection(final Socket socket) {
        new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    BufferedReader in = new BufferedReader(new InputStreamReader(socket.getInputStream()));
                    String requestLine = in.readLine();
                    if (requestLine == null) {
                        socket.close();
                        return;
                    }

                    Log.d(TAG, "Request: " + requestLine);
                    String[] parts = requestLine.split(" ");
                    if (parts.length < 2) {
                        socket.close();
                        return;
                    }

                    String urlStr = parts[1];
                    URL url = new URL("http://localhost" + urlStr);
                    String path = url.getPath();
                    Map<String, String> params = parseQueryParams(url.getQuery());

                    // Any request that is not weather/location data is forwarded directly to the legacy maps server
                    if (!isWeatherDataRequest(path)) {
                        forwardMapsRequest(urlStr, socket);
                        return;
                    }

                    String responseJson = "";
                    if (path.contains("/v1/mobile-app/sites") || path.contains("/sites")) {
                        responseJson = handleSites(params);
                    } else if (path.contains("/hourly")) {
                        responseJson = handleHourly(params);
                    } else if (path.contains("/daily")) {
                        responseJson = handleDaily(params);
                    } else if (path.contains("/auto-fill")) {
                        responseJson = handleAutoFill(params);
                    } else if (path.contains("/warnings")) {
                        responseJson = "{\"type\":\"FeatureCollection\",\"features\":[]}";
                    } else if (path.contains("/notifications")) {
                        responseJson = "{\"enabled\":false}";
                    } else if (path.contains("/update")) {
                        responseJson = "{\"showTakeover\":false}";
                    } else {
                        responseJson = "{}";
                    }

                    OutputStream out = socket.getOutputStream();
                    PrintWriter writer = new PrintWriter(out);
                    writer.print("HTTP/1.1 200 OK\r\n");
                    writer.print("Content-Type: application/json\r\n");
                    writer.print("Connection: close\r\n");
                    writer.print("Access-Control-Allow-Origin: *\r\n");
                    writer.print("\r\n");
                    writer.print(responseJson);
                    writer.flush();
                    socket.close();
                } catch (Exception e) {
                    Log.e(TAG, "Connection error", e);
                    try {
                        socket.close();
                    } catch (Exception ignored) {}
                }
            }
        }).start();
    }

    private static boolean isWeatherDataRequest(String path) {
        return path.contains("/sites") || 
               path.contains("/hourly") || 
               path.contains("/daily") || 
               path.contains("/auto-fill") || 
               path.contains("/warnings") || 
               path.contains("/notifications") || 
               path.contains("/update") ||
               path.contains("/pollen") ||
               path.contains("/videos");
    }

    private static void forwardMapsRequest(String pathWithParams, Socket socket) {
        try {
            Log.d(TAG, "Forwarding maps request: " + pathWithParams);
            String targetUrl = "https://maps.consumer-digital.api.metoffice.gov.uk" + pathWithParams;
            URL url = new URL(targetUrl);
            HttpURLConnection conn = (HttpURLConnection) url.openConnection();
            conn.setRequestMethod("GET");
            conn.setConnectTimeout(10000);
            conn.setReadTimeout(15000);

            int responseCode = conn.getResponseCode();
            String contentType = conn.getContentType();

            OutputStream out = socket.getOutputStream();
            PrintWriter writer = new PrintWriter(out);
            writer.print("HTTP/1.1 " + responseCode + " OK\r\n");
            if (contentType != null) {
                writer.print("Content-Type: " + contentType + "\r\n");
            }
            writer.print("Connection: close\r\n");
            writer.print("\r\n");
            writer.flush();

            InputStream in = (responseCode >= 400) ? conn.getErrorStream() : conn.getInputStream();
            if (in != null) {
                byte[] buffer = new byte[4096];
                int bytesRead;
                while ((bytesRead = in.read(buffer)) != -1) {
                    out.write(buffer, 0, bytesRead);
                }
                in.close();
            }
            out.flush();
            socket.close();
            Log.d(TAG, "Maps request successfully forwarded");
        } catch (Exception e) {
            Log.e(TAG, "Maps forwarding error", e);
            try { socket.close(); } catch (Exception ignored) {}
        }
    }

    private static Map<String, String> parseQueryParams(String query) {
        Map<String, String> params = new HashMap<>();
        if (query == null) return params;
        String[] pairs = query.split("&");
        for (String pair : pairs) {
            String[] kv = pair.split("=");
            if (kv.length == 2) {
                params.put(kv[0], kv[1]);
            } else if (kv.length == 1) {
                params.put(kv[0], "");
            }
        }
        return params;
    }

    private static String getCachedResponse(String key) {
        try {
            File cacheDir = getCacheDir();
            File cacheFile = new File(cacheDir, "proxy_cache_" + key + ".json");
            if (cacheFile.exists() && (System.currentTimeMillis() - cacheFile.lastModified()) < CACHE_TTL_MS) {
                BufferedReader reader = new BufferedReader(new FileReader(cacheFile));
                StringBuilder sb = new StringBuilder();
                String line;
                while ((line = reader.readLine()) != null) {
                    sb.append(line);
                }
                reader.close();
                Log.d(TAG, "CACHE HIT: returned cached data for " + key);
                return sb.toString();
            }
        } catch (Exception e) {
            Log.e(TAG, "Cache read error", e);
        }
        return null;
    }

    private static void saveCacheResponse(String key, String data) {
        try {
            File cacheDir = getCacheDir();
            File cacheFile = new File(cacheDir, "proxy_cache_" + key + ".json");
            BufferedWriter writer = new BufferedWriter(new FileWriter(cacheFile));
            writer.write(data);
            writer.close();
            Log.d(TAG, "CACHE WRITE: saved fresh response for " + key);
        } catch (Exception e) {
            Log.e(TAG, "Cache write error", e);
        }
    }

    private static String roundTo3Decimals(String val) {
        try {
            double d = Double.parseDouble(val);
            return String.format(Locale.US, "%.3f", d);
        } catch (Exception e) {
            return val;
        }
    }

    private static String fetchUrl(String urlStr) throws Exception {
        URL url = new URL(urlStr);
        HttpURLConnection conn = (HttpURLConnection) url.openConnection();
        conn.setRequestMethod("GET");
        conn.setRequestProperty("apikey", API_KEY);
        conn.setRequestProperty("accept", "application/json");
        conn.setConnectTimeout(10000);
        conn.setReadTimeout(10000);

        BufferedReader reader = new BufferedReader(new InputStreamReader(conn.getInputStream()));
        StringBuilder sb = new StringBuilder();
        String line;
        while ((line = reader.readLine()) != null) {
            sb.append(line);
        }
        reader.close();
        return sb.toString();
    }

    private static String handleSites(Map<String, String> params) {
        String lat = params.get("lat");
        String lon = params.get("long");
        if (lat == null) lat = "51.507";
        if (lon == null) lon = "-0.127";

        try {
            JSONObject data = new JSONObject();
            data.put("name", "My Location");
            data.put("timezone", "Europe/London");
            data.put("latitude", Double.parseDouble(lat));
            data.put("longitude", Double.parseDouble(lon));
            data.put("geohash", "gcpvnyg");
            data.put("type", "city");
            data.put("unitaryAuthority", "UK");

            JSONObject links = new JSONObject();
            links.put("daily_snapshot", "http://127.0.0.1:18080/v1/mobile-app/daily?lat=" + lat + "&lon=" + lon);
            links.put("detailed_forecast", "http://127.0.0.1:18080/v1/mobile-app/hourly?lat=" + lat + "&lon=" + lon);
            links.put("snapshot", "http://127.0.0.1:18080/v1/mobile-app/hourly?lat=" + lat + "&lon=" + lon);
            data.put("links", links);

            JSONObject response = new JSONObject();
            response.put("apiResponseTime", System.currentTimeMillis());
            response.put("data", data);
            return response.toString();
        } catch (Exception e) {
            return "{\"error\":\"" + e.getMessage() + "\"}";
        }
    }

    private static String handleHourly(Map<String, String> params) {
        String lat = params.get("lat");
        String lon = params.get("lon");
        if (lat == null) lat = "51.507";
        if (lon == null) lon = "-0.127";

        String cacheKey = roundTo3Decimals(lat) + "_" + roundTo3Decimals(lon) + "_hourly";
        String cached = getCachedResponse(cacheKey);
        if (cached != null) {
            return cached;
        }

        try {
            // Query three-hourly endpoint which returns 8 full days of data instead of 2 days
            String rawJson = fetchUrl("https://data.hub.api.metoffice.gov.uk/sitespecific/v0/point/three-hourly?latitude=" + lat + "&longitude=" + lon);
            JSONObject hubData = new JSONObject(rawJson);
            JSONArray timeSeries = hubData.getJSONArray("features").getJSONObject(0).getJSONObject("properties").getJSONArray("timeSeries");

            Map<String, List<JSONObject>> daysMap = new LinkedHashMap<>();
            for (int i = 0; i < timeSeries.length(); i++) {
                JSONObject step = timeSeries.getJSONObject(i);
                String time = step.getString("time");
                String dateStr = time.split("T")[0];

                if (!daysMap.containsKey(dateStr)) {
                    daysMap.put(dateStr, new ArrayList<JSONObject>());
                }

                int windDir = step.optInt("windDirectionFrom10m", 0);
                String compass = getCompassDirection(windDir);

                // Check both three-hourly temperature fields (maxScreenAirTemp) and falls back
                double temp = step.optDouble("screenTemperature", step.optDouble("maxScreenAirTemp", 15.0));
                double feelsLike = step.optDouble("feelsLikeTemp", step.optDouble("feelsLikeTemperature", temp));

                JSONObject mappedStep = new JSONObject();
                mappedStep.put("datetime_start", time);
                mappedStep.put("datetime_end", addHours(time, 3)); // End time is 3 hours later
                mappedStep.put("actual_temp_celsius", temp);
                mappedStep.put("feels_like_temp_celsius", feelsLike);
                // Append percentage symbol to formatting
                mappedStep.put("precipitation_probability", step.optInt("probOfPrecipitation", 0) + "%");
                mappedStep.put("precipitation_probability_value", step.optInt("probOfPrecipitation", 0));
                mappedStep.put("weather_symbol", step.optInt("significantWeatherCode", 1));
                mappedStep.put("weather_type", getWeatherTypeString(step.optInt("significantWeatherCode", 1)));
                mappedStep.put("wind_speed_ms", step.optDouble("windSpeed10m", 2.0));
                mappedStep.put("wind_gust_ms", step.optDouble("windGustSpeed10m", step.optDouble("windSpeed10m", 2.0)));
                mappedStep.put("wind_direction", compass);
                mappedStep.put("uv_rating", String.valueOf(step.optInt("uvIndex", 0)));
                mappedStep.put("visibility_metre", step.optInt("visibility", 10000));
                mappedStep.put("visibility", getVisibilityString(step.optInt("visibility", 10000)));
                mappedStep.put("visibility_key", getShortVisibilityKey(step.optInt("visibility", 10000)));
                mappedStep.put("humidity", step.optInt("screenRelativeHumidity", 50));
                mappedStep.put("pressure_hpa", step.optDouble("mslp", 101300.0) / 100.0);

                daysMap.get(dateStr).add(mappedStep);
            }

            JSONArray daysArray = new JSONArray();
            for (Map.Entry<String, List<JSONObject>> entry : daysMap.entrySet()) {
                // Calculate high/low summaries for each day to populate summary cards correctly
                double maxTemp = -999;
                double minTemp = 999;
                int daySymbol = 1;
                int nightSymbol = 1;
                double minDiffDay = 999999;
                double minDiffNight = 999999;

                for (JSONObject t : entry.getValue()) {
                    double stepTemp = t.optDouble("actual_temp_celsius", 15.0);
                    if (stepTemp > maxTemp) maxTemp = stepTemp;
                    if (stepTemp < minTemp) minTemp = stepTemp;

                    String tTime = t.getString("datetime_start");
                    int hour = 12;
                    try {
                        hour = Integer.parseInt(tTime.split("T")[1].split(":")[0]);
                    } catch (Exception ignored) {}
                    int symbol = t.optInt("weather_symbol", 1);

                    int diffDay = Math.abs(hour - 12);
                    if (diffDay < minDiffDay) {
                        minDiffDay = diffDay;
                        daySymbol = symbol;
                    }

                    int diffNight = Math.abs(hour - 23);
                    if (diffNight < minDiffNight) {
                        minDiffNight = diffNight;
                        nightSymbol = symbol;
                    }
                }

                JSONObject dayObj = new JSONObject();
                dayObj.put("date", entry.getKey());
                dayObj.put("day_actual_temp_celsius", maxTemp);
                dayObj.put("day_weather_symbol", daySymbol);
                dayObj.put("night_actual_temp_celsius", minTemp);
                dayObj.put("night_weather_symbol", nightSymbol);
                dayObj.put("sunset_datetime", entry.getKey() + "T20:15:00Z");
                dayObj.put("sun_will_set", true);
                dayObj.put("sunrise_datetime", entry.getKey() + "T05:30:00Z");
                dayObj.put("sun_will_rise", true);

                JSONArray timeStepsArray = new JSONArray();
                for (JSONObject t : entry.getValue()) {
                    timeStepsArray.put(t);
                }
                dayObj.put("time_steps", timeStepsArray);
                daysArray.put(dayObj);
            }

            JSONObject dataObj = new JSONObject();
            dataObj.put("days", daysArray);

            JSONObject response = new JSONObject();
            response.put("apiResponseTime", System.currentTimeMillis());
            response.put("data", dataObj);
            
            String finalJson = response.toString();
            saveCacheResponse(cacheKey, finalJson);
            return finalJson;
        } catch (Exception e) {
            return "{\"error\":\"" + e.getMessage() + "\"}";
        }
    }

    private static String handleDaily(Map<String, String> params) {
        String lat = params.get("lat");
        String lon = params.get("lon");
        if (lat == null) lat = "51.507";
        if (lon == null) lon = "-0.127";

        String cacheKey = roundTo3Decimals(lat) + "_" + roundTo3Decimals(lon) + "_daily";
        String cached = getCachedResponse(cacheKey);
        if (cached != null) {
            return cached;
        }

        try {
            String rawJson = fetchUrl("https://data.hub.api.metoffice.gov.uk/sitespecific/v0/point/daily?latitude=" + lat + "&longitude=" + lon);
            JSONObject hubData = new JSONObject(rawJson);
            JSONArray timeSeries = hubData.getJSONArray("features").getJSONObject(0).getJSONObject("properties").getJSONArray("timeSeries");

            JSONArray daysArray = new JSONArray();
            for (int i = 0; i < timeSeries.length(); i++) {
                JSONObject step = timeSeries.getJSONObject(i);
                String time = step.getString("time");
                String dateStr = time.split("T")[0];

                int daySymbol = step.optInt("daySignificantWeatherCode", step.optInt("nightSignificantWeatherCode", 1));
                int nightSymbol = step.optInt("nightSignificantWeatherCode", 1);

                JSONObject dayObj = new JSONObject();
                dayObj.put("date", dateStr);
                dayObj.put("day_actual_temp_celsius", step.optDouble("dayMaxScreenTemperature", 15.0));
                dayObj.put("day_weather_symbol", daySymbol);
                dayObj.put("night_actual_temp_celsius", step.optDouble("nightMinScreenTemperature", 10.0));
                dayObj.put("night_weather_symbol", nightSymbol);
                dayObj.put("sunset_datetime", dateStr + "T20:15:00Z");
                dayObj.put("sun_will_set", true);

                daysArray.put(dayObj);
            }

            JSONObject dataObj = new JSONObject();
            dataObj.put("days", daysArray);

            JSONObject response = new JSONObject();
            response.put("apiResponseTime", System.currentTimeMillis());
            response.put("data", dataObj);
            
            String finalJson = response.toString();
            saveCacheResponse(cacheKey, finalJson);
            return finalJson;
        } catch (Exception e) {
            return "{\"error\":\"" + e.getMessage() + "\"}";
        }
    }

    private static String handleAutoFill(Map<String, String> params) {
        String query = params.get("q");
        if (query == null || query.isEmpty()) return "[]";

        try {
            URL url = new URL("https://nominatim.openstreetmap.org/search?q=" + URLEncoder.encode(query, "UTF-8") + "&format=json&limit=10&addressdetails=1");
            HttpURLConnection conn = (HttpURLConnection) url.openConnection();
            conn.setRequestMethod("GET");
            conn.setRequestProperty("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)");
            conn.setConnectTimeout(10000);
            conn.setReadTimeout(10000);

            BufferedReader reader = new BufferedReader(new InputStreamReader(conn.getInputStream()));
            StringBuilder sb = new StringBuilder();
            String line;
            while ((line = reader.readLine()) != null) {
                sb.append(line);
            }
            reader.close();

            JSONArray results = new JSONArray(sb.toString());
            JSONArray locations = new JSONArray();

            for (int i = 0; i < results.length(); i++) {
                JSONObject item = results.getJSONObject(i);
                String displayName = item.getString("display_name");
                String[] parts = displayName.split(",");
                String name = parts[0].trim();
                String desc = parts.length > 1 ? parts[1].trim() : "Location";

                JSONObject loc = new JSONObject();
                loc.put("name", name);
                loc.put("latitude", Double.parseDouble(item.getString("lat")));
                loc.put("longitude", Double.parseDouble(item.getString("lon")));
                loc.put("geohash", "gcpvnyg");
                loc.put("type", item.optString("type", "city"));
                loc.put("unitaryAuthority", desc);
                locations.put(loc);
            }

            return locations.toString();
        } catch (Exception e) {
            return "[]";
        }
    }

    private static String addHours(String isoString, int hours) {
        try {
            SimpleDateFormat sdf = new SimpleDateFormat("yyyy-MM-dd'T'HH:mm'Z'", Locale.US);
            sdf.setTimeZone(TimeZone.getTimeZone("UTC"));
            Date d = sdf.parse(isoString.replace(":00.000", ""));
            Calendar cal = Calendar.getInstance();
            cal.setTime(d);
            cal.add(Calendar.HOUR_OF_DAY, hours);
            return sdf.format(cal.getTime());
        } catch (Exception e) {
            return isoString;
        }
    }

    private static String getCompassDirection(int deg) {
        String[] directions = {"N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"};
        int val = (int) ((deg / 22.5) + 0.5);
        return directions[val % 16];
    }

    private static String getWeatherTypeString(int code) {
        switch (code) {
            case 0: return "Clear night";
            case 1: return "Sunny day";
            case 2:
            case 3: return "Partly cloudy";
            case 5: return "Mist";
            case 6: return "Fog";
            case 7: return "Cloudy";
            case 8: return "Overcast";
            case 9:
            case 10: return "Light rain shower";
            case 11: return "Drizzle";
            case 12: return "Light rain";
            case 13:
            case 14: return "Heavy rain shower";
            case 15: return "Heavy rain";
            case 16:
            case 17: return "Sleet shower";
            case 18: return "Sleet";
            case 19:
            case 20: return "Hail shower";
            case 21: return "Hail";
            case 22:
            case 23: return "Light snow shower";
            case 24: return "Light snow";
            case 25:
            case 26: return "Heavy snow shower";
            case 27: return "Heavy snow";
            case 28:
            case 29: return "Thunder shower";
            case 30: return "Thunder";
            default: return "Cloudy";
        }
    }

    private static String getVisibilityString(int meters) {
        if (meters < 1000) return "Very Poor";
        if (meters < 4000) return "Poor";
        if (meters < 10000) return "Moderate";
        if (meters < 20000) return "Good";
        if (meters < 40000) return "Very Good";
        return "Excellent";
    }

    private static String getShortVisibilityKey(int meters) {
        if (meters < 1000) return "VP";
        if (meters < 4000) return "PO";
        if (meters < 10000) return "MO";
        if (meters < 20000) return "GO";
        if (meters < 40000) return "VG";
        return "EX";
    }
}
