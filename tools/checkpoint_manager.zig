extern fn execute(command: [*:0]const u8) u8;

pub fn main() u8 {
    return execute("checkpoint");
}
