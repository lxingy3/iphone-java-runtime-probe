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
    public static void main(String[] args) throws Exception { run(); }
    public static void run() throws Exception {
        results.clear();
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
