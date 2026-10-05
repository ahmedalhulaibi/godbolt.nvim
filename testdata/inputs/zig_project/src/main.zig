const helper = @import("helper");
const options = @import("build_options");
export fn calculate(value: i32) i32 {
    return helper.increment(value) + options.offset;
}
pub fn main() void {}
