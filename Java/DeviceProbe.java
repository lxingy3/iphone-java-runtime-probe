import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.*;
import java.util.*;
import java.util.concurrent.*;

public final class DeviceProbe {
    public static final class BeanProbe {
        private String value;
        public String getValue() { return value; }
        public void setValue(String value) { this.value = value; }
    }
    interface Test { void run() throws Exception; }
    static final Map<String,String> results = new LinkedHashMap<>();
    static void check(String name, Test test) {
        System.err.println("Probe: starting " + name);
        try { test.run(); results.put(name,"PASS"); }
        catch (Throwable failure) { results.put(name,"FAIL: " + failure); }
        System.err.println("Probe: " + name + " " + results.get(name));
    }
    private static URLClassLoader serverLoader;
    public static void main(String[] args) throws Exception {
        if (args.length == 2 && args[0].equals("--prepare")) prepareServer(args[1]);
        else if (args.length == 2 && args[0].equals("--server")) { prepareServer(args[1]); startServer(); }
        else run();
    }
    public static void prepareServer(String documents) throws Exception {
        prepareServer(documents, null);
    }
    public static String sha256File(String filename) throws Exception {
        MessageDigest hash = MessageDigest.getInstance("SHA-256");
        byte[] buffer = new byte[1024 * 1024];
        try (InputStream input = Files.newInputStream(Path.of(filename))) {
            for (int count; (count = input.read(buffer)) != -1;) hash.update(buffer, 0, count);
        }
        return HexFormat.of().formatHex(hash.digest());
    }
    private static void extractionProgress(Path source, int completed, int total, long bytes) throws IOException {
        Path temporary = source.resolve("payload-progress.tmp");
        Files.writeString(temporary, "{\"completed_files\":" + completed + ",\"total_files\":" + total +
            ",\"extracted_bytes\":" + bytes + "}", StandardCharsets.UTF_8);
        Files.move(temporary, source.resolve("payload-progress.json"), StandardCopyOption.REPLACE_EXISTING);
    }
    // The native host passes a digest computed from this file during this launch,
    // not a persisted assertion that a file may be trusted without verification.
    public static void prepareServer(String documents, String nativeDigest) throws Exception {
        Path source = Path.of(documents).toAbsolutePath().normalize();
        Path archive = source.resolve("server-payload.zip");
        Path root = source.resolve("server");
        String expected = Files.readString(source.resolve("server-payload.sha256")).trim().toLowerCase(Locale.ROOT);
        if (!expected.matches("[0-9a-f]{64}")) throw new IOException("Invalid payload checksum file");
        Path marker = root.resolve(".payload-ready.sha256");
        if (Files.isRegularFile(marker)) {
            if (!Files.readString(marker).trim().equals(expected))
                throw new IOException("An existing server uses a different payload; refusing to overwrite saved data");
            requireServerFiles(root);
            System.err.println("Payload: reusing prepared files and persistent database");
            return;
        }
        if (Files.exists(root.resolve("iphone-save.mv")) || Files.exists(root.resolve("iphone-save.mv.mv.db")) || Files.exists(root.resolve("seed-imported.marker")))
            throw new IOException("Existing saved data has no payload marker; manual review required");
        byte[] buffer = new byte[1024 * 1024];
        System.err.println("Payload: verifying archive checksum");
        String actual = nativeDigest == null ? sha256File(archive.toString()) : nativeDigest;
        if (!actual.equals(expected)) throw new IOException("Payload checksum mismatch");
        System.err.println("Payload: checksum verified using " + (nativeDigest == null ? "Java" : "native SHA-256"));
        int totalEntries;
        try (var index = new java.util.zip.ZipFile(archive.toFile())) { totalEntries = index.size(); }
        if (totalEntries > 100000) throw new IOException("Payload has too many entries");
        extractionProgress(source, 0, totalEntries, 0);
        Files.createDirectories(root);
        final long limit = 8L * 1024 * 1024 * 1024;
        long total = 0;
        int entries = 0;
        System.err.println("Payload: extracting local archive");
        try (var zip = new java.util.zip.ZipInputStream(new BufferedInputStream(Files.newInputStream(archive), buffer.length))) {
            for (java.util.zip.ZipEntry entry; (entry = zip.getNextEntry()) != null;) {
                if (++entries > 100000) throw new IOException("Payload has too many entries");
                String name = entry.getName();
                Path target = root.resolve(name).normalize();
                if (name.isEmpty() || name.contains("\\") || name.contains(":") || name.startsWith("/") ||
                    !target.startsWith(root) || target.equals(root) || target.equals(marker))
                    throw new IOException("Invalid payload entry path");
                if (entry.isDirectory()) Files.createDirectories(target);
                else {
                    Files.createDirectories(target.getParent());
                    try (OutputStream output = new BufferedOutputStream(Files.newOutputStream(target), buffer.length)) {
                        for (int count; (count = zip.read(buffer)) != -1;) {
                            total += count;
                            if (total > limit) throw new IOException("Payload exceeds extraction limit");
                            output.write(buffer, 0, count);
                        }
                    }
                }
                if (entries % 1000 == 0) extractionProgress(source, entries, totalEntries, total);
                if (entries % 5000 == 0) System.err.println("Payload: " + entries + " entries, " + total + " bytes");
                zip.closeEntry();
            }
        }
        requireServerFiles(root);
        Files.writeString(marker, expected + "\n", StandardCharsets.UTF_8);
        extractionProgress(source, entries, totalEntries, total);
        System.err.println("Payload: prepared " + entries + " entries, " + total + " bytes");
    }
    private static void requireServerFiles(Path root) throws IOException {
        for (String file : new String[]{"portable-launcher.jar", "grasscutter.jar", "config.json", "prototype-logback.xml"})
            if (!Files.isRegularFile(root.resolve(file))) throw new IOException("Required server file missing: " + file);
        if (!Files.isDirectory(root.resolve("lib")) || !Files.isDirectory(root.resolve("resources")))
            throw new IOException("Required server directories are missing");
    }
    public static void startServer() throws Exception {
        if (serverLoader != null) throw new IllegalStateException("Server already started in this process");
        Path root = Path.of("").toAbsolutePath();
        requireServerFiles(root);
        List<Path> jars = new ArrayList<>();
        jars.add(root.resolve("portable-launcher.jar"));
        try (var dependencies = Files.list(root.resolve("lib"))) {
            jars.addAll(dependencies.filter(p -> p.getFileName().toString().endsWith(".jar")).sorted().toList());
        }
        jars.add(root.resolve("grasscutter.jar"));
        URL[] urls = new URL[jars.size()];
        for (int i = 0; i < jars.size(); i++) urls[i] = jars.get(i).toUri().toURL();
        serverLoader = new URLClassLoader(urls, DeviceProbe.class.getClassLoader());
        Thread.currentThread().setContextClassLoader(serverLoader);
        System.setProperty("java.class.path", String.join(File.pathSeparator, jars.stream().map(Path::toString).toList()));
        System.err.println("Server: loading embedded launcher with " + jars.size() + " JARs");
        try {
            Class.forName("local.iphone.StartupProbe", true, serverLoader)
                .getMethod("main", String[].class).invoke(null, (Object)new String[0]);
        } catch (java.lang.reflect.InvocationTargetException failure) {
            Throwable cause = failure.getCause();
            if (cause instanceof Exception exception) throw exception;
            if (cause instanceof Error error) throw error;
            throw failure;
        }
    }
    private static int legacyValue(boolean valid) throws Exception {
        byte[] bytes = Base64.getDecoder().decode("yv66vgAAADEADwoAAgADBwAEDAAFAAYBABBqYXZhL2xhbmcvT2JqZWN0AQAGPGluaXQ+AQADKClWBwAIAQAVTGVnYWN5VmVyaWZpZXJGaXh0dXJlAQAEQ29kZQEAD0xpbmVOdW1iZXJUYWJsZQEABXZhbHVlAQADKClJAQAKU291cmNlRmlsZQEAGkxlZ2FjeVZlcmlmaWVyRml4dHVyZS5qYXZhACEABwACAAAAAAACAAEABQAGAAEACQAAAB0AAQABAAAABSq3AAGxAAAAAQAKAAAABgABAAAAAQAJAAsADAABAAkAAAAbAAEAAAAAAAMQB6wAAAABAAoAAAAGAAEAAAABAAEADQAAAAIADg==");
        if (!valid) {
            for (int i = 0; i < bytes.length - 2; i++) {
                if (bytes[i] == 0x10 && bytes[i+1] == 7 && (bytes[i+2] & 255) == 0xac) {
                    bytes[i+2] = (byte)0xb0; break; // areturn is invalid for a primitive int result.
                }
            }
        }
        class FixtureLoader extends ClassLoader {
            Class<?> loadFixture(byte[] data) { return defineClass(null, data, 0, data.length); }
        }
        return (Integer)new FixtureLoader().loadFixture(bytes).getMethod("value").invoke(null);
    }
    public static void run() throws Exception {
        results.clear();
        check("legacy_bytecode_verifier", () -> {
            if (legacyValue(true) != 7) throw new IOException("Legacy bytecode result mismatch");
        });
        check("invalid_legacy_bytecode_rejected", () -> {
            try { legacyValue(false); throw new IOException("Invalid bytecode was accepted"); }
            catch (VerifyError rejected) {
                if (String.valueOf(rejected.getMessage()).contains("Could not link verifier")) throw rejected;
            }
        });
        check("required_modules", () -> {
            for (String name : new String[]{"java.lang.management.ManagementFactory", "javax.management.MBeanServer",
                 "java.sql.SQLException", "javax.naming.Context", "javax.xml.parsers.DocumentBuilderFactory", "sun.misc.Unsafe",
                 "java.beans.Transient", "java.rmi.Remote", "javax.script.ScriptEngineManager",
                 "java.lang.instrument.Instrumentation", "org.ietf.jgss.GSSException"})
                Class.forName(name);
        });
        check("javabeans_introspection", () -> {
            BeanProbe bean = new BeanProbe();
            var descriptor = Arrays.stream(java.beans.Introspector.getBeanInfo(BeanProbe.class).getPropertyDescriptors())
                .filter(p -> p.getName().equals("value")).findFirst().orElseThrow();
            descriptor.getWriteMethod().invoke(bean,"bean-ok");
            if (!descriptor.getReadMethod().invoke(bean).equals("bean-ok")) throw new IOException("Bean accessor mismatch");
        });
        check("scheduled_executor", () -> {
            var executor = Executors.newSingleThreadScheduledExecutor();
            try {
                if (!executor.schedule(() -> "timer-ok",25,TimeUnit.MILLISECONDS).get(5,TimeUnit.SECONDS).equals("timer-ok"))
                    throw new IOException("Scheduled task mismatch");
            } finally { executor.shutdownNow(); }
        });
        check("file_persistence", () -> {
            var file=Path.of("probe-storage.txt");
            String value="local-server-probe";
            Files.writeString(file,value);
            if (!Files.readString(file).equals(value)) throw new IOException("File round-trip changed");
        });
        check("file_watch_service", () -> {
            Path directory = Files.createTempDirectory("probe-watch-");
            try (var watcher = FileSystems.getDefault().newWatchService()) {
                directory.register(watcher, java.nio.file.StandardWatchEventKinds.ENTRY_CREATE);
                Files.writeString(directory.resolve("event.txt"), "watch-ok");
                var key = watcher.poll(10, TimeUnit.SECONDS);
                if (key == null || key.pollEvents().stream().noneMatch(event ->
                    event.kind() == java.nio.file.StandardWatchEventKinds.ENTRY_CREATE &&
                    Path.of("event.txt").equals(event.context()))) throw new IOException("File notification missing");
            } finally {
                Files.deleteIfExists(directory.resolve("event.txt"));
                Files.deleteIfExists(directory);
            }
        });
        check("jar_filesystem", () -> {
            Path archive=Path.of("probe-resource.zip").toAbsolutePath();
            try(var output=new java.util.zip.ZipOutputStream(Files.newOutputStream(archive))) {
                output.putNextEntry(new java.util.zip.ZipEntry("defaults/probe.txt"));
                output.write("resource-ok".getBytes(StandardCharsets.UTF_8));
                output.closeEntry();
            }
            try(var filesystem=FileSystems.newFileSystem(URI.create("jar:"+archive.toUri()),Map.of())) {
                if(!Files.readString(filesystem.getPath("/defaults/probe.txt")).equals("resource-ok"))
                    throw new IOException("JAR resource mismatch");
            } finally { Files.deleteIfExists(archive); }
        });
        check("platform_threads", () -> {
            var done=new CountDownLatch(1);
            new Thread(done::countDown).start();
            if(!done.await(5,TimeUnit.SECONDS)) throw new IOException("Thread timed out");
        });
        check("reflection", () -> {
            if(!String.class.getMethod("substring",int.class).invoke("probe",1).equals("robe")) throw new IOException("Reflection failed");
        });
        check("tcp_loopback", () -> {
            try(var server=new ServerSocket(0,1,InetAddress.getByName("127.0.0.1"));
                var client=new Socket("127.0.0.1",server.getLocalPort()); var accepted=server.accept()) {
                client.setSoTimeout(3000); accepted.setSoTimeout(3000);
                client.getOutputStream().write(42);
                if(accepted.getInputStream().read()!=42) throw new IOException("TCP mismatch");
            }
        });
        check("udp_loopback", () -> {
            try(var receiver=new DatagramSocket(new InetSocketAddress("127.0.0.1",0));var sender=new DatagramSocket()) {
                receiver.setSoTimeout(3000);
                sender.send(new DatagramPacket(new byte[]{42},1,InetAddress.getByName("127.0.0.1"),receiver.getLocalPort()));
                var packet=new DatagramPacket(new byte[8],8); receiver.receive(packet);
                if(packet.getLength()!=1||packet.getData()[0]!=42) throw new IOException("UDP mismatch");
            }
        });
        check("rsa", () -> {
            var generator=KeyPairGenerator.getInstance("RSA");generator.initialize(2048);var keys=generator.generateKeyPair();
            var signature=Signature.getInstance("SHA256withRSA");signature.initSign(keys.getPrivate());signature.update(new byte[]{42});
            byte[] signed=signature.sign();signature.initVerify(keys.getPublic());signature.update(new byte[]{42});
            if(!signature.verify(signed)) throw new GeneralSecurityException("RSA mismatch");
        });
        check("xml", () -> javax.xml.parsers.DocumentBuilderFactory.newInstance().newDocumentBuilder()
             .parse(new ByteArrayInputStream("<probe/>".getBytes(StandardCharsets.UTF_8))));
        check("management", () -> {
            if(java.lang.management.ManagementFactory.getMemoryMXBean().getHeapMemoryUsage().getUsed()<=0)
                throw new IOException("No memory usage");
        });
        boolean passed=results.values().stream().allMatch("PASS"::equals);
        StringBuilder json=new StringBuilder("{\n  \"passed\": ").append(passed)
            .append(",\n  \"vm\": ").append(quote(System.getProperty("java.vm.name")))
            .append(",\n  \"java_version\": ").append(quote(System.getProperty("java.version")))
            .append(",\n  \"os\": ").append(quote(System.getProperty("os.name"))).append(",\n  \"checks\": {");
        String separator="";
        for(var entry:results.entrySet()){json.append(separator).append("\n    ").append(quote(entry.getKey())).append(": ").append(quote(entry.getValue()));separator=",";}
        json.append("\n  }\n}\n");Files.writeString(Path.of("runtime-probe.json"),json.toString());
    }
    static String quote(String value){return "\""+value.replace("\\","\\\\").replace("\"","\\\"").replace("\n","\\n").replace("\r","\\r")+"\"";}
}
