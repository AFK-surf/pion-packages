s = f"{x!r:>{width}} and {'nested'}"
t = 1
b = rb'''multi
line # not a comment
'''
v = 3
@app.route("/x")
def handler(req):
    return req  # it's fine
