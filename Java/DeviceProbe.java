import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.*;
import java.util.*;
import java.util.concurrent.*;

public final class DeviceProbe {
    interface Test { void run() throws Exception; }
    static final Map<String,String> results = new LinkedHashMap<>();
    static void check(String name, Test test) {
        try { test.run(); results.put(name,"PASS"); }
        catch (Throwable failure) { results.put(name,"FAIL: " + failure); }
    }
    public static void main(String[] args) throws Exception { run(); }
    public static void run() throws Exception {
        results.clear();
        check("required_modules", () -> {
            for (String name : new String[]{"java.lang.management.ManagementFactory", "javax.management.MBeanServer",
                 "java.sql.SQLException", "javax.naming.Context", "javax.xml.parsers.DocumentBuilderFactory", "sun.misc.Unsafe"})
                Class.forName(name);
        });
        check("file_persistence", () -> {
            var file=Path.of("probe-storage.txt");
            String value="local-server-probe";
            Files.writeString(file,value);
            if (!Files.readString(file).equals(value)) throw new IOException("File round-trip changed");
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
            .append(",\n  \"os\": ").append(quote(System.getProperty("os.name"))).append(",\n  \"checks\": {");
        String separator="";
        for(var entry:results.entrySet()){json.append(separator).append("\n    ").append(quote(entry.getKey())).append(": ").append(quote(entry.getValue()));separator=",";}
        json.append("\n  }\n}\n");Files.writeString(Path.of("runtime-probe.json"),json.toString());
    }
    static String quote(String value){return "\""+value.replace("\\","\\\\").replace("\"","\\\"").replace("\n","\\n").replace("\r","\\r")+"\"";}
}
