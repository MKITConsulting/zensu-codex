# Resolve a feature ID to its UUID

Every `<feature-id>` argument of the `zensu` CLI takes the feature UUID. A `KEY-N` id (e.g. `ZEN-42`) or a slug fails with `invalid feature id (status 400, code bad_request)`. When the user names a feature by anything other than its UUID, resolve it before any other `zensu` call:

1. **Automatic package**: when an automatic context package was supplied for this `KEY-N`, its `feature_id` is already the UUID. Use it and skip the lookup.
2. **`KEY-N`**: run `zensu products list --json` and take, from its `data` array, the product whose `feature_key` equals `KEY` exactly, never one whose key merely starts with it (`ZEN-42` never matches a product keyed `ZENX`). Run the filter below with that product's `id` and `N`.
3. **A slug**: ask the user which product it belongs to unless they named it, take from `zensu products list --json` the one product whose `name`, `slug` or `feature_key` equals what the user named, and run the filter below with that product's `id` and the slug.
4. **No match**: when no product's `feature_key` equals `KEY`, when the product the user named matches no product or more than one in the `zensu products list --json` output, when a `zensu` command fails (it prints an error instead of the JSON envelope, so the filter fails too), or when the filter prints `no single match`, show the user what you looked up and the command's error if one failed, and ask again; never guess a feature, and never pass the unresolved id to a `<feature-id>` argument.

`zensu features list --product <product-id> --json` prints every feature of the product in one envelope, far too much to read, so never print it unfiltered. The filter keeps a feature only when its `product_id` is the product's `id` and its `number` equals `N` as an integer (`ZEN-001` is number 1) or its `slug` equals the slug, and prints only that feature's `id`:

```bash
zensu features list --product '<product-id>' --json | node -e '
let s = "";
process.stdin.on("data", (d) => { s += d; }).on("end", () => {
  const [product, key] = process.argv.slice(1);
  const n = /^[0-9]+$/.test(key) ? Number(key) : null;
  const hits = JSON.parse(s).data.filter((f) => f.product_id === product && (n === null ? f.slug === key : f.number === n));
  console.log(hits.length === 1 ? hits[0].id : "no single match (" + hits.length + ")");
});' '<product-id>' '<N or slug>'
```

Replace each placeholder with its value inside the single quotes, and write each apostrophe in a value as `'\''`. The printed UUID is the `<feature-id>` of every later command.
