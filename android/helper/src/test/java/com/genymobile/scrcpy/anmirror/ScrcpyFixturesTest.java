package com.genymobile.scrcpy.anmirror;

import com.genymobile.scrcpy.audio.AudioCodec;
import com.genymobile.scrcpy.control.ControlMessage;
import com.genymobile.scrcpy.control.ControlMessageReader;
import com.genymobile.scrcpy.control.DeviceMessage;
import com.genymobile.scrcpy.control.DeviceMessageWriter;
import com.genymobile.scrcpy.device.DesktopConnection;
import com.genymobile.scrcpy.device.Streamer;
import com.genymobile.scrcpy.util.StringUtils;
import com.genymobile.scrcpy.video.VideoCodec;

import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import org.junit.Assert;
import org.junit.Test;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.EOFException;
import java.io.File;
import java.io.IOException;
import java.lang.reflect.Field;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Arrays;

/**
 * Cross-checks protocol/vectors/scrcpy.json (the Mac's authority for the scrcpy v5.0.1 wire format)
 * against the vendored server: the control fixtures are parsed by the real ControlMessageReader, the
 * device fixtures are written by the real DeviceMessageWriter, and the stream fixtures are checked
 * against the server's codec IDs, packet flags and device-name field.
 */
public class ScrcpyFixturesTest {

    private static JsonObject load() throws IOException {
        File dir = new File(System.getProperty("anmirror.vectors", "../../protocol/vectors"));
        String json = new String(Files.readAllBytes(new File(dir, "scrcpy.json").toPath()), StandardCharsets.UTF_8);
        return JsonParser.parseString(json).getAsJsonObject();
    }

    private static byte[] hex(String s) {
        byte[] out = new byte[s.length() / 2];
        for (int i = 0; i < out.length; i++) {
            out[i] = (byte) Integer.parseInt(s.substring(2 * i, 2 * i + 2), 16);
        }
        return out;
    }

    private static byte[] concat(byte[] a, byte[] b) {
        byte[] out = Arrays.copyOf(a, a.length + b.length);
        System.arraycopy(b, 0, out, a.length, b.length);
        return out;
    }

    /** Binary.u16FixedPointToFloat, from the wire value. */
    private static float pressure(int u16) {
        return u16 == 0xffff ? 1f : u16 / 0x1p16f;
    }

    /** The reader's scroll value from the wire i16 (Binary.i16FixedPointToFloat x 16). */
    private static float scroll(int i16) {
        return (i16 == 0x7fff ? 1f : i16 / 0x1p15f) * 16;
    }

    /** The C client's encoder (control_msg.c + sc_float_to_i16fp), in float arithmetic like upstream. */
    private static int clientScrollI16(float v) {
        float norm = Math.max(-1f, Math.min(1f, v / 16));
        int i = (int) (norm * 0x1p15f); // C float-to-int conversion: truncation toward zero
        return i >= 0x7fff ? 0x7fff : i;
    }

    @Test
    public void controlFixturesParse() throws IOException {
        JsonArray control = load().getAsJsonArray("control");
        Assert.assertFalse(control.isEmpty());
        for (JsonElement element : control) {
            JsonObject entry = element.getAsJsonObject();
            String name = entry.get("name").getAsString();
            JsonObject f = entry.getAsJsonObject("fields");
            // A trailing ROTATE_DEVICE proves the reader consumed exactly the fixture's bytes.
            byte[] bytes = concat(hex(entry.get("hex").getAsString()), new byte[] {ControlMessage.TYPE_ROTATE_DEVICE});
            ControlMessageReader reader = new ControlMessageReader(new ByteArrayInputStream(bytes));
            ControlMessage msg = reader.read();
            Assert.assertEquals(name, ControlMessage.TYPE_ROTATE_DEVICE, reader.read().getType());
            try {
                reader.read();
                Assert.fail(name + ": trailing bytes");
            } catch (EOFException expected) {
                // the stream ends exactly after the sentinel
            }

            int type = f.get("type").getAsInt();
            Assert.assertEquals(name, type, msg.getType());
            switch (type) {
                case ControlMessage.TYPE_INJECT_KEYCODE:
                    Assert.assertEquals(name, f.get("action").getAsInt(), msg.getAction());
                    Assert.assertEquals(name, f.get("keycode").getAsInt(), msg.getKeycode());
                    Assert.assertEquals(name, f.get("repeat").getAsInt(), msg.getRepeat());
                    Assert.assertEquals(name, f.get("meta_state").getAsInt(), msg.getMetaState());
                    break;
                case ControlMessage.TYPE_INJECT_TEXT:
                    Assert.assertEquals(name, f.get("text").getAsString(), msg.getText());
                    Assert.assertTrue(name, msg.getText().getBytes(StandardCharsets.UTF_8).length
                            <= ControlMessageReader.INJECT_TEXT_MAX_LENGTH);
                    break;
                case ControlMessage.TYPE_INJECT_TOUCH_EVENT:
                    Assert.assertEquals(name, f.get("action").getAsInt(), msg.getAction());
                    Assert.assertEquals(name, f.get("pointer_id").getAsLong(), msg.getPointerId());
                    Assert.assertEquals(name, f.get("x").getAsInt(), msg.getPosition().getPoint().getX());
                    Assert.assertEquals(name, f.get("y").getAsInt(), msg.getPosition().getPoint().getY());
                    Assert.assertEquals(name, f.get("width").getAsInt(), msg.getPosition().getScreenSize().getWidth());
                    Assert.assertEquals(name, f.get("height").getAsInt(), msg.getPosition().getScreenSize().getHeight());
                    Assert.assertEquals(name, pressure(f.get("pressure").getAsInt()), msg.getPressure(), 0f);
                    Assert.assertEquals(name, f.get("action_button").getAsInt(), msg.getActionButton());
                    Assert.assertEquals(name, f.get("buttons").getAsInt(), msg.getButtons());
                    break;
                case ControlMessage.TYPE_INJECT_SCROLL_EVENT:
                    Assert.assertEquals(name, f.get("x").getAsInt(), msg.getPosition().getPoint().getX());
                    Assert.assertEquals(name, f.get("y").getAsInt(), msg.getPosition().getPoint().getY());
                    Assert.assertEquals(name, f.get("width").getAsInt(), msg.getPosition().getScreenSize().getWidth());
                    Assert.assertEquals(name, f.get("height").getAsInt(), msg.getPosition().getScreenSize().getHeight());
                    int h = f.get("hscroll_i16").getAsInt();
                    int v = f.get("vscroll_i16").getAsInt();
                    Assert.assertEquals(name, scroll(h), msg.getHScroll(), 0f);
                    Assert.assertEquals(name, scroll(v), msg.getVScroll(), 0f);
                    // The wire values are what upstream's C client sends for the encoder inputs.
                    Assert.assertEquals(name, clientScrollI16(f.get("hscroll").getAsFloat()), h);
                    Assert.assertEquals(name, clientScrollI16(f.get("vscroll").getAsFloat()), v);
                    Assert.assertEquals(name, f.get("buttons").getAsInt(), msg.getButtons());
                    break;
                case ControlMessage.TYPE_BACK_OR_SCREEN_ON:
                    Assert.assertEquals(name, f.get("action").getAsInt(), msg.getAction());
                    break;
                case ControlMessage.TYPE_GET_CLIPBOARD:
                    Assert.assertEquals(name, f.get("copy_key").getAsInt(), msg.getCopyKey());
                    break;
                case ControlMessage.TYPE_SET_CLIPBOARD:
                    Assert.assertEquals(name, f.get("sequence").getAsLong(), msg.getSequence());
                    Assert.assertEquals(name, f.get("paste").getAsBoolean(), msg.getPaste());
                    Assert.assertEquals(name, f.get("text").getAsString(), msg.getText());
                    Assert.assertTrue(name, msg.getText().getBytes(StandardCharsets.UTF_8).length
                            <= ControlMessageReader.CLIPBOARD_TEXT_MAX_LENGTH);
                    break;
                case ControlMessage.TYPE_SET_DISPLAY_POWER:
                    Assert.assertEquals(name, f.get("on").getAsBoolean(), msg.getOn());
                    break;
                case ControlMessage.TYPE_ROTATE_DEVICE:
                case ControlMessage.TYPE_RESET_VIDEO:
                    Assert.assertEquals(name, 1, f.size());
                    break;
                default:
                    Assert.fail(name + ": no check for type " + type);
            }
        }
    }

    @Test
    public void deviceFixturesWrite() throws IOException {
        JsonArray device = load().getAsJsonArray("device");
        Assert.assertFalse(device.isEmpty());
        for (JsonElement element : device) {
            JsonObject entry = element.getAsJsonObject();
            String name = entry.get("name").getAsString();
            JsonObject f = entry.getAsJsonObject("fields");
            DeviceMessage msg;
            switch (f.get("type").getAsInt()) {
                case DeviceMessage.TYPE_CLIPBOARD:
                    msg = DeviceMessage.createClipboard(f.get("text").getAsString());
                    break;
                case DeviceMessage.TYPE_ACK_CLIPBOARD:
                    msg = DeviceMessage.createAckClipboard(f.get("sequence").getAsLong());
                    break;
                case DeviceMessage.TYPE_UHID_OUTPUT:
                    msg = DeviceMessage.createUhidOutput(f.get("id").getAsInt(), hex(f.get("data_hex").getAsString()));
                    break;
                default:
                    throw new AssertionError(name + ": unknown type");
            }
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            new DeviceMessageWriter(out).write(msg);
            Assert.assertArrayEquals(name, hex(entry.get("hex").getAsString()), out.toByteArray());
        }
    }

    @Test
    public void limitsMatchServer() throws Exception {
        JsonObject limits = load().getAsJsonObject("limits");
        Assert.assertEquals(ControlMessageReader.INJECT_TEXT_MAX_LENGTH, limits.get("inject_text_max_bytes").getAsInt());
        Assert.assertEquals(ControlMessageReader.CLIPBOARD_TEXT_MAX_LENGTH, limits.get("set_clipboard_text_max_bytes").getAsInt());
        Assert.assertEquals(DeviceMessageWriter.CLIPBOARD_TEXT_MAX_LENGTH, limits.get("device_clipboard_text_max_bytes").getAsInt());
        Assert.assertEquals(privateStatic(DesktopConnection.class, "DEVICE_NAME_FIELD_LENGTH"),
                (long) limits.get("device_name_bytes").getAsInt());
    }

    @Test
    public void streamFixturesMatchServer() throws Exception {
        long session = privateStatic(Streamer.class, "PACKET_FLAG_SESSION");
        long config = privateStatic(Streamer.class, "PACKET_FLAG_CONFIG");
        long keyFrame = privateStatic(Streamer.class, "PACKET_FLAG_KEY_FRAME");
        int nameLength = (int) privateStatic(DesktopConnection.class, "DEVICE_NAME_FIELD_LENGTH");

        for (JsonElement element : load().getAsJsonArray("stream")) {
            JsonObject entry = element.getAsJsonObject();
            String name = entry.get("name").getAsString();
            JsonObject f = entry.getAsJsonObject("fields");
            ByteBuffer b = ByteBuffer.wrap(hex(entry.get("hex").getAsString()));
            if (f.has("device_name")) {
                // DesktopConnection.open writes the dummy byte, sendDeviceMeta the name, Streamer.writeVideoHeader the codec
                Assert.assertTrue(name, f.get("dummy_byte").getAsBoolean());
                Assert.assertEquals(name, 0, b.get());
                byte[] raw = f.get("device_name").getAsString().getBytes(StandardCharsets.UTF_8);
                byte[] field = new byte[nameLength];
                System.arraycopy(raw, 0, field, 0, StringUtils.getUtf8TruncationIndex(raw, nameLength - 1));
                byte[] actual = new byte[nameLength];
                b.get(actual);
                Assert.assertArrayEquals(name, field, actual);
                int id = b.getInt();
                Assert.assertEquals(name, VideoCodec.findByName(f.get("codec").getAsString()).getId(), id);
                Assert.assertEquals(name, f.get("codec_id").getAsInt(), id);
            } else if (f.has("session")) {
                // Streamer.writeSessionMeta with isClientResize = false
                Assert.assertEquals(name, (int) (session >> 32), b.getInt());
                Assert.assertEquals(name, f.get("width").getAsInt(), b.getInt());
                Assert.assertEquals(name, f.get("height").getAsInt(), b.getInt());
            } else if (f.has("pts_us")) {
                // Streamer.writeFrameMeta
                long expected = f.get("config").getAsBoolean() ? config
                        : f.get("pts_us").getAsLong() | (f.get("key_frame").getAsBoolean() ? keyFrame : 0);
                Assert.assertEquals(name, expected, b.getLong());
                Assert.assertEquals(name, f.get("size").getAsInt(), b.getInt());
            } else {
                // Streamer.writeAudioHeader, or writeDisableStream(false / true)
                String codec = f.get("codec").getAsString();
                int expected = codec.equals("disabled") ? 0 : codec.equals("error") ? 1 : AudioCodec.findByName(codec).getId();
                Assert.assertEquals(name, expected, b.getInt());
                Assert.assertEquals(name, f.get("codec_id").getAsInt(), expected);
            }
            Assert.assertFalse(name + ": trailing bytes", b.hasRemaining());
        }
    }

    private static long privateStatic(Class<?> cls, String field) throws ReflectiveOperationException {
        Field f = cls.getDeclaredField(field);
        f.setAccessible(true);
        return ((Number) f.get(null)).longValue();
    }
}
