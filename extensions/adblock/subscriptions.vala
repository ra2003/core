/*
 Copyright (C) 2009-2014 Christian Dywan <christian@twotoasts.de>
 Copyright (C) 2009-2012 Alexander Butenko <a.butenka@gmail.com>

 This library is free software; you can redistribute it and/or
 modify it under the terms of the GNU Lesser General Public
 License as published by the Free Software Foundation; either
 version 2.1 of the License, or (at your option) any later version.

 See the file COPYING for the full license text.
*/

namespace Adblock {
    public abstract class Feature : GLib.Object {
        public virtual bool header (string key, string value) {
            return false;
        }
        public virtual Directive? match (string request_uri, string page_uri) throws Error {
            return null;
        }
        public virtual void clear () {
        }
    }

    public class Subscription : GLib.Object {
        public string? path;
        public string uri { get; set; default = null; }
        public bool active { get; set; default = true; }
        List<Feature> features;
        public Pattern pattern;
        public Keys keys;
        public Options optslist;
        public Whitelist whitelist;
        public Element element;
        WebKit.Download? download;

        public Subscription (string uri) {
            this.uri = uri;

            this.optslist = new Options ();
            this.whitelist = new Whitelist (optslist);
            add_feature (this.whitelist);
            this.keys = new Keys (optslist);
            add_feature (this.keys);
            this.pattern = new Pattern (optslist);
            add_feature (this.pattern);
            this.element = new Element ();
            add_feature (this.element);
            clear ();
        }

        public void add_feature (Feature feature) {
            features.append (feature);
            size++;
        }

        /* foreach support */
        public new Feature? get (uint index) {
            return features.nth_data (index);
        }
        public uint size { get; private set; }

        public void clear () {
            foreach (var feature in features)
                feature.clear ();
            optslist.clear ();
        }

        internal void parse_line (string? line) throws Error {
            if (line.has_prefix ("@@")) {
                if (line.contains("$") && line.contains ("domain"))
                    return;
                if (line.has_prefix ("@@||"))
                    add_url_pattern ("^", "whitelist", line.offset (4));
                else if (line.has_prefix ("@@|"))
                    add_url_pattern ("^", "whitelist", line.offset (3));
                else
                    add_url_pattern ("", "whitelist", line.offset (2));
                return;
            }
            /* TODO: [include] [exclude] */
            if (line[0] == '[')
                return;

            /* CSS block hider */
            if (line.has_prefix ("##")) {
                /* TODO */
                return;
            }
            if (line[0] == '#')
                return;

            /* Per domain CSS hider rule */
            if ("##" in line) {
                frame_add_private (line, "##");
                return;
            }
            if ("#" in line) {
                frame_add_private (line, "#");
                return;
            }

            /* URL blocker rule */
            if (line.has_prefix ("|")) {
                /* TODO: handle options and domains excludes */
                if (line.contains("$"))
                    return;

                if (line.has_prefix ("||"))
                    add_url_pattern ("", "fulluri", line.offset (2));
                else
                    add_url_pattern ("^", "fulluri", line.offset (1));
                return /* add_url_pattern */;
            }

            add_url_pattern ("", "uri", line);
            return /* add_url_pattern */;
        }

        void frame_add_private (string line, string sep) {
            string[] data = line.split (sep, 2);
            if (!(data[1] != null && data[1] != "")
             ||  data[1].chr (-1, '\'') != null
             || (data[1].chr (-1, ':') != null
             && !Regex.match_simple (".*\\[.*:.*\\].*", data[1],
                RegexCompileFlags.CASELESS, RegexMatchFlags.NOTEMPTY))) {
                return;
            }

            if (data[0].chr (-1, ',') != null) {
                string[] domains = data[0].split (",", -1);

                foreach (string domain in domains) {
                    /* Ignore Firefox-specific option */
                    if (domain == "~pregecko2")
                        continue;
                    /* FIXME: ~ should negate match */
                    if (domain[0] == '~')
                        domain = domain.substring (1, -1);
                    update_css_hash (domain.strip (), data[1]);
                }
            }
            else {
                update_css_hash (data[0], data[1]);
            }
        }

        void update_css_hash (string domain, string value) {
            string? olddata = element.lookup (domain);
            if (olddata != null) {
                string newdata = olddata + " , " + value;
                element.insert (domain, newdata);
            } else {
                element.insert (domain, value);
            }
        }

        void add_url_pattern (string prefix, string type, string line) throws Error {
            string[]? data = line.split ("$", 2);
            if (data == null || data[0] == null)
                return;

            string patt, opts;
            patt = data[0];
            opts = type;

            if (data[1] != null)
                opts = type + "," + data[1];

            if (Regex.match_simple ("subdocument", opts,
                RegexCompileFlags.CASELESS, RegexMatchFlags.NOTEMPTY))
                return;

            string format_patt = fixup_regex (prefix, patt);
            debug ("got: %s opts %s", format_patt, opts);
            compile_regexp (format_patt, opts);
            /* return format_patt */
        }

        bool compile_regexp (string? patt, string opts) throws Error {
            if (patt == null)
                return false;
            try {
                var regex = new Regex (patt, RegexCompileFlags.OPTIMIZE, RegexMatchFlags.NOTEMPTY);
                /* is pattern is already a regex? */
                if (Regex.match_simple ("^/.*[\\^\\$\\*].*/$", patt,
                    RegexCompileFlags.UNGREEDY, RegexMatchFlags.NOTEMPTY)
                 || opts != null && opts.contains ("whitelist")) {
                    debug ("patt: %s", patt);
                    if (opts.contains ("whitelist"))
                        this.whitelist.insert (patt, regex);
                    else
                        this.pattern.insert (patt, regex);
                    this.optslist.insert (patt, opts);
                    return false;
                } else { /* nope, no regex */
                    int pos = 0, len;
                    int signature_size = 8;
                    string sig;
                    len = patt.length;

                    /* chop up pattern into substrings for faster matching */
                    for (pos = len - signature_size; pos>=0; pos--)
                    {
                        sig = patt.offset (pos).ndup (signature_size);
                        /* we don't have a * nor \\, does not look like regex, save chunk as "key" */
                        if (!Regex.match_simple ("[\\*]", sig, RegexCompileFlags.UNGREEDY, RegexMatchFlags.NOTEMPTY) && keys.lookup (sig) == null) {
                            this.keys.insert (sig, regex);
                            this.optslist.insert (sig, opts);
                        } else {
                            /* starts with * or \\ - save as regex */
                            if ((sig.has_prefix ("*") || sig.has_prefix("\\")) && this.pattern.lookup (sig) == null) {
                                this.pattern.insert (sig, regex);
                                this.optslist.insert (sig, opts);
                            }
                        }
                    }
                }
                return false;
            }
            catch (Error error) {
                warning ("Adblock compile regexp: %s", error.message);
                return true;
            }
        }

        public void parse_header (string header) throws Error {
            /* Headers come in two forms
               ! Foo: Bar
               ! Some freeform text
             */
            string key = header;
            string value = "";
            if (header.contains (":")) {
                string[] parts = header.split (":", 2);
                if (parts[0] != null) {
                    key = parts[0].substring (2, -1);
                    value = parts[1].substring (1, -1);
                }
            }
            debug ("Header '%s' says '%s'", key, value);
            foreach (var feature in features) {
                if (feature.header (key, value))
                    break;
            }
        }

        void download_status (ParamSpec pspec) {
            if (download.get_status () != WebKit.DownloadStatus.FINISHED)
                return;

            download = null;
            try {
                parse ();
            } catch (Error error) {
                warning ("Error parsing %s: %s", uri, error.message);
            }
        }

        public void parse () throws Error
        {
            if (!active)
                return;

            debug ("Parsing %s (%s)", uri, path);

            clear ();

            if (uri.has_prefix ("file://"))
                path = Filename.from_uri (uri);
            else {
                string cache_dir = GLib.Path.build_filename (GLib.Environment.get_home_dir (), ".cache", "midori", "adblock");
                Midori.Paths.mkdir_with_parents (cache_dir);
                string filename = Checksum.compute_for_string (ChecksumType.MD5, this.uri, -1);
                path = GLib.Path.build_filename (cache_dir, filename);
            }

            File filter_file = File.new_for_path (path);
            DataInputStream stream;
            try  {
                stream = new DataInputStream (filter_file.read ());
            } catch (IOError.NOT_FOUND exist_error) {
#if HAVE_WEBKIT2
                /* TODO */
#else
                if (download != null)
                    return;

                string destination_uri = Filename.to_uri (path, null);
                debug ("Fetching %s to %s now", uri, destination_uri);
                download = new WebKit.Download (new WebKit.NetworkRequest (uri));
                if (!Midori.Download.has_enough_space (download, destination_uri, true))
                     throw new FileError.EXIST ("Can't download to \"%s\"", path);
                download.destination_uri = destination_uri;
                download.notify["status"].connect (download_status);
                download.start ();
#endif
                return;
            }

            string? line;
            while ((line = stream.read_line (null)) != null) {
                if (line == null)
                    continue;
                string chomped = line.chomp ();
                if (chomped == "")
                    continue;
                if (line[0] == '!')
                    parse_header (chomped);
                else
                    parse_line (chomped);
            }
        }

        public Directive? get_directive (string request_uri, string page_uri) {
            try {
                foreach (var feature in features) {
                    Directive? directive = feature.match (request_uri, page_uri);
                    if (directive != null) {
                        debug ("%s gave %s for %s (%s)\n",
                               feature.get_type ().name (), directive.to_string (), request_uri, page_uri);
                        return directive;
                    }
                }
            } catch (Error error) {
                warning ("Adblock match error: %s\n", error.message);
            }
            return null;
        }
    }
}
