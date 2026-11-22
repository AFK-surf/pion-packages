fn parse<'a>(input: &'a str) -> Result<&'a str, char> {
    let quote = '\'';
    let emoji = '\u{1F600}';
    let bytes = b"\x00\xff";
    let byte = b'x';
    let raw = r##"a "# still raw"##;
    let cstr = c"hello";
    /* outer /* inner */ still comment */
    'outer: loop { break 'outer; }
    let v = vec![1, 2, 3];
    Ok(&input[1..])
}
