const std = @import("std");
const hashing = @import("../util/hashing.zig");

pub const TokenKind = enum(u8) {
    word,
    number,
    mixed,
    symbol,
};

pub const Token = struct {
    text: []const u8,
    stem: []const u8,
    start: usize,
    end: usize,
    kind: TokenKind,
    field: u8,
    position: u32,
    sentence: u32,
    stopword: bool,

    pub fn release(self: *Token, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.stem);
    }
};

pub const Options = struct {
    lowercase: bool = true,
    fold_diacritics: bool = true,
    strip_possessives: bool = true,
    split_on_punctuation: bool = true,
    keep_numbers: bool = true,
    min_token_length: u32 = 1,
    max_token_length: u32 = 64,
    enable_stemming: bool = true,
    mark_stopwords: bool = true,
    language: []const u8 = "",
};

const fold_table = "aaaaaaaceeeeiiiidnoooooxouuuuytsaaaaaaaceeeeiiiidnooooo/ouuuuytyaaaaaaccccccccddddeeeeeeeeeegggggggghhhhiiiiiiiiiiiijjkkkllllllllllnnnnnnnnnoooooooorrrrrrssssssssttttttuuuuuuuuuuuuwwyyyzzzzzzs";

pub fn foldDiacritics(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    var index: usize = 0;
    while (index < input.len) {
        const byte = input[index];
        if (byte < 0x80) {
            try out.append(byte);
            index += 1;
            continue;
        }
        const length = std.unicode.utf8ByteSequenceLength(byte) catch {
            try out.append(byte);
            index += 1;
            continue;
        };
        if (index + length > input.len) {
            try out.append(byte);
            index += 1;
            continue;
        }
        const codepoint = std.unicode.utf8Decode(input[index .. index + length]) catch {
            try out.append(byte);
            index += 1;
            continue;
        };
        if (codepoint >= 0xC0 and codepoint <= 0x17F) {
            const folded = foldLatin(codepoint);
            if (folded != 0) {
                var buffer: [4]u8 = undefined;
                const written = std.unicode.utf8Encode(folded, &buffer) catch 0;
                try out.appendSlice(buffer[0..written]);
                index += length;
                continue;
            }
        }
        try out.appendSlice(input[index .. index + length]);
        index += length;
    }
    return out.toOwnedSlice();
}

fn foldLatin(codepoint: u21) u21 {
    if (codepoint >= 0xC0 and codepoint <= 0x17F) {
        const folded = fold_table[codepoint - 0xC0];
        if (folded >= 0x80) return codepoint;
        return @as(u21, folded);
    }
    return codepoint;
}

pub fn normalizeWhitespace(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    var pending_space = false;
    var index: usize = 0;
    while (index < input.len) {
        const byte = input[index];
        const length = if (byte < 0x80) 1 else (std.unicode.utf8ByteSequenceLength(byte) catch 1);
        if (std.ascii.isWhitespace(byte)) {
            pending_space = true;
            index += 1;
            continue;
        }
        if (pending_space and out.items.len > 0) try out.append(' ');
        pending_space = false;
        if (index + length <= input.len) {
            try out.appendSlice(input[index .. index + length]);
        }
        index += length;
    }
    const trimmed = std.mem.trim(u8, out.items, " ");
    const result = try allocator.dupe(u8, trimmed);
    out.deinit();
    return result;
}

pub fn canonicalText(allocator: std.mem.Allocator, input: []const u8, options: Options) ![]u8 {
    const lowered = if (options.lowercase) try std.ascii.allocLowerString(allocator, input) else try allocator.dupe(u8, input);
    defer allocator.free(lowered);
    const folded = if (options.fold_diacritics) try foldDiacritics(allocator, lowered) else try allocator.dupe(u8, lowered);
    defer allocator.free(folded);
    var spaced: []u8 = undefined;
    if (options.split_on_punctuation) {
        var builder = std.ArrayList(u8).init(allocator);
        errdefer builder.deinit();
        for (folded) |byte| {
            if (isSeparator(byte)) {
                try builder.append(' ');
            } else {
                try builder.append(byte);
            }
        }
        spaced = try builder.toOwnedSlice();
    } else {
        spaced = try allocator.dupe(u8, folded);
    }
    defer allocator.free(spaced);
    return normalizeWhitespace(allocator, spaced);
}

fn isSeparator(byte: u8) bool {
    if (byte < 0x80) {
        if (std.ascii.isAlphanumeric(byte)) return false;
        if (byte == '_' or byte == '\'' or byte == '-') return false;
        return true;
    }
    return false;
}

pub fn isStopword(word: []const u8, language: []const u8) bool {
    if (word.len == 0) return false;
    if (language.len == 0 or std.mem.eql(u8, language, "en")) return englishStopwords.has(word);
    const set = stopwordSet(language) orelse return false;
    return set.has(word);
}

fn stopwordSet(language: []const u8) ?std.StaticStringMap(void) {
    if (std.mem.startsWith(u8, language, "de")) return german_stopwords;
    if (std.mem.startsWith(u8, language, "fr")) return french_stopwords;
    if (std.mem.startsWith(u8, language, "es")) return spanish_stopwords;
    if (std.mem.startsWith(u8, language, "hu")) return hungarian_stopwords;
    if (std.mem.startsWith(u8, language, "it")) return italian_stopwords;
    if (std.mem.startsWith(u8, language, "pt")) return portuguese_stopwords;
    if (std.mem.startsWith(u8, language, "nl")) return dutch_stopwords;
    if (std.mem.startsWith(u8, language, "ru")) return russian_stopwords;
    return null;
}

const englishStopwords = std.StaticStringMap(void).initComptime(.{
    .{"a"}, .{"about"}, .{"above"}, .{"after"}, .{"again"}, .{"all"}, .{"also"}, .{"am"}, .{"an"}, .{"and"},
    .{"any"}, .{"are"}, .{"as"}, .{"at"}, .{"be"}, .{"because"}, .{"been"}, .{"before"}, .{"being"}, .{"below"},
    .{"between"}, .{"both"}, .{"but"}, .{"by"}, .{"can"}, .{"could"}, .{"did"}, .{"do"}, .{"does"}, .{"doing"},
    .{"down"}, .{"during"}, .{"each"}, .{"few"}, .{"for"}, .{"from"}, .{"further"}, .{"had"}, .{"has"}, .{"have"},
    .{"having"}, .{"he"}, .{"her"}, .{"here"}, .{"hers"}, .{"herself"}, .{"him"}, .{"himself"}, .{"his"}, .{"how"},
    .{"i"}, .{"if"}, .{"in"}, .{"into"}, .{"is"}, .{"it"}, .{"its"}, .{"itself"}, .{"just"}, .{"me"},
    .{"more"}, .{"most"}, .{"my"}, .{"myself"}, .{"no"}, .{"nor"}, .{"not"}, .{"now"}, .{"of"}, .{"off"},
    .{"on"}, .{"once"}, .{"only"}, .{"or"}, .{"other"}, .{"our"}, .{"ours"}, .{"ourselves"}, .{"out"}, .{"over"},
    .{"own"}, .{"s"}, .{"same"}, .{"she"}, .{"should"}, .{"so"}, .{"some"}, .{"such"}, .{"t"}, .{"than"},
    .{"that"}, .{"the"}, .{"their"}, .{"theirs"}, .{"them"}, .{"themselves"}, .{"then"}, .{"there"}, .{"these"}, .{"they"},
    .{"this"}, .{"those"}, .{"through"}, .{"to"}, .{"too"}, .{"under"}, .{"until"}, .{"up"}, .{"very"}, .{"was"},
    .{"we"}, .{"were"}, .{"what"}, .{"when"}, .{"where"}, .{"which"}, .{"while"}, .{"who"}, .{"whom"}, .{"why"},
    .{"will"}, .{"with"}, .{"you"}, .{"your"}, .{"yours"}, .{"yourself"}, .{"yourselves"},
});

const german_stopwords = std.StaticStringMap(void).initComptime(.{
    .{"aber"}, .{"alle"}, .{"allem"}, .{"allen"}, .{"aller"}, .{"alles"}, .{"als"}, .{"also"}, .{"am"}, .{"an"},
    .{"ander"}, .{"andere"}, .{"anderem"}, .{"anderen"}, .{"anderer"}, .{"anderes"}, .{"auch"}, .{"auf"}, .{"aus"}, .{"bei"},
    .{"bin"}, .{"bis"}, .{"bist"}, .{"da"}, .{"damit"}, .{"dann"}, .{"der"}, .{"den"}, .{"des"}, .{"dem"},
    .{"die"}, .{"das"}, .{"dass"}, .{"derselbe"}, .{"dazu"}, .{"dein"}, .{"deine"}, .{"denn"}, .{"derer"}, .{"dessen"},
    .{"dich"}, .{"dir"}, .{"du"}, .{"dies"}, .{"diese"}, .{"diesem"}, .{"diesen"}, .{"dieser"}, .{"dieses"}, .{"doch"},
    .{"dort"}, .{"durch"}, .{"ein"}, .{"eine"}, .{"einem"}, .{"einen"}, .{"einer"}, .{"eines"}, .{"einig"}, .{"er"},
    .{"es"}, .{"etwas"}, .{"euer"}, .{"fuer"}, .{"gegen"}, .{"gewesen"}, .{"hab"}, .{"habe"}, .{"haben"}, .{"hat"},
    .{"hatte"}, .{"hatten"}, .{"hier"}, .{"hin"}, .{"hinter"}, .{"ich"}, .{"ihm"}, .{"ihn"}, .{"ihnen"}, .{"ihr"},
    .{"im"}, .{"in"}, .{"indem"}, .{"ins"}, .{"ist"}, .{"jede"}, .{"jedem"}, .{"jeden"}, .{"jeder"}, .{"jedes"},
    .{"jene"}, .{"jetzt"}, .{"kann"}, .{"kein"}, .{"kannst"}, .{"koennen"}, .{"machen"}, .{"man"}, .{"manche"}, .{"mein"},
    .{"mich"}, .{"mir"}, .{"mit"}, .{"muss"}, .{"musste"}, .{"nach"}, .{"nicht"}, .{"nichts"}, .{"noch"}, .{"nun"},
    .{"nur"}, .{"ob"}, .{"oder"}, .{"ohne"}, .{"sehr"}, .{"sein"}, .{"seine"}, .{"seinem"}, .{"seinen"}, .{"seiner"},
    .{"selbst"}, .{"sich"}, .{"sie"}, .{"sind"}, .{"so"}, .{"solche"}, .{"soll"}, .{"sollte"}, .{"sondern"}, .{"sonst"},
    .{"ueber"}, .{"um"}, .{"und"}, .{"uns"}, .{"unse"}, .{"unter"}, .{"viel"}, .{"vom"}, .{"von"}, .{"vor"},
    .{"war"}, .{"waren"}, .{"warst"}, .{"was"}, .{"weg"}, .{"weil"}, .{"weiter"}, .{"welche"}, .{"wenn"}, .{"werde"},
    .{"werden"}, .{"wie"}, .{"wieder"}, .{"will"}, .{"wir"}, .{"wird"}, .{"wirst"}, .{"wo"}, .{"wollen"}, .{"wollte"},
    .{"wuerde"}, .{"wuerden"}, .{"zu"}, .{"zum"}, .{"zur"}, .{"zwar"}, .{"zwischen"},
});

const french_stopwords = std.StaticStringMap(void).initComptime(.{
    .{"alors"}, .{"au"}, .{"aucuns"}, .{"aussi"}, .{"autre"}, .{"avant"}, .{"avec"}, .{"avoir"}, .{"bon"}, .{"car"},
    .{"ce"}, .{"cela"}, .{"ces"}, .{"ceux"}, .{"chaque"}, .{"ci"}, .{"comme"}, .{"comment"}, .{"dans"}, .{"des"},
    .{"de"}, .{"dedans"}, .{"dehors"}, .{"depuis"}, .{"deux"}, .{"devrait"}, .{"doit"}, .{"donc"}, .{"dont"}, .{"du"},
    .{"elle"}, .{"elles"}, .{"en"}, .{"encore"}, .{"essai"}, .{"est"}, .{"et"}, .{"etaient"}, .{"etait"}, .{"etant"},
    .{"etc"}, .{"etre"}, .{"eu"}, .{"fait"}, .{"faire"}, .{"fois"}, .{"font"}, .{"hors"}, .{"ici"}, .{"il"},
    .{"ils"}, .{"je"}, .{"juste"}, .{"la"}, .{"laquelle"}, .{"le"}, .{"lequel"}, .{"les"}, .{"lesquelles"}, .{"leur"},
    .{"leurs"}, .{"lui"}, .{"ma"}, .{"mais"}, .{"me"}, .{"meme"}, .{"mes"}, .{"moi"}, .{"mon"}, .{"ne"},
    .{"ni"}, .{"nommes"}, .{"nos"}, .{"notre"}, .{"nous"}, .{"on"}, .{"ont"}, .{"ou"}, .{"oui"}, .{"par"},
    .{"parce"}, .{"pas"}, .{"peu"}, .{"peut"}, .{"plupart"}, .{"plus"}, .{"pour"}, .{"pourquoi"}, .{"quand"}, .{"que"},
    .{"quel"}, .{"quelle"}, .{"quelles"}, .{"quels"}, .{"qui"}, .{"quoi"}, .{"sa"}, .{"sans"}, .{"se"}, .{"sera"},
    .{"serait"}, .{"ses"}, .{"seulement"}, .{"si"}, .{"sien"}, .{"son"}, .{"sont"}, .{"sous"}, .{"soyez"}, .{"sujet"},
    .{"sur"}, .{"ta"}, .{"tandis"}, .{"te"}, .{"tels"}, .{"tes"}, .{"toi"}, .{"ton"}, .{"tous"}, .{"tout"},
    .{"trop"}, .{"très"}, .{"tu"}, .{"un"}, .{"une"}, .{"va"}, .{"vers"}, .{"voient"}, .{"vont"}, .{"vos"},
    .{"votre"}, .{"vous"}, .{"vu"},
});

const spanish_stopwords = std.StaticStringMap(void).initComptime(.{
    .{"al"}, .{"algo"}, .{"algunas"}, .{"algunos"}, .{"ante"}, .{"antes"}, .{"como"}, .{"con"}, .{"contra"}, .{"cual"},
    .{"cuando"}, .{"de"}, .{"del"}, .{"desde"}, .{"donde"}, .{"durante"}, .{"e"}, .{"el"}, .{"ella"}, .{"ellas"},
    .{"ellos"}, .{"en"}, .{"entre"}, .{"era"}, .{"erais"}, .{"eran"}, .{"eras"}, .{"eres"}, .{"es"}, .{"esa"},
    .{"esas"}, .{"ese"}, .{"eso"}, .{"esos"}, .{"esta"}, .{"estaba"}, .{"estabais"}, .{"estaban"}, .{"estabas"}, .{"estad"},
    .{"estada"}, .{"estadas"}, .{"estado"}, .{"estados"}, .{"estamos"}, .{"estan"}, .{"estar"}, .{"estas"}, .{"este"}, .{"esto"},
    .{"estos"}, .{"estoy"}, .{"fue"}, .{"fueron"}, .{"fui"}, .{"fuimos"}, .{"ha"}, .{"habeis"}, .{"haber"}, .{"habia"},
    .{"habida"}, .{"habidas"}, .{"habido"}, .{"habidos"}, .{"han"}, .{"has"}, .{"hasta"}, .{"hay"}, .{"haya"}, .{"he"},
    .{"hemos"}, .{"la"}, .{"las"}, .{"le"}, .{"les"}, .{"lo"}, .{"los"}, .{"me"}, .{"mi"}, .{"mia"},
    .{"mio"}, .{"mis"}, .{"mucho"}, .{"muchos"}, .{"muy"}, .{"nada"}, .{"ni"}, .{"no"}, .{"nos"}, .{"nosotras"},
    .{"nosotros"}, .{"nuestra"}, .{"nuestro"}, .{"o"}, .{"os"}, .{"otra"}, .{"otras"}, .{"otro"}, .{"otros"}, .{"para"},
    .{"pero"}, .{"poco"}, .{"por"}, .{"porque"}, .{"que"}, .{"quien"}, .{"quienes"}, .{"se"}, .{"sea"}, .{"seais"},
    .{"sean"}, .{"seas"}, .{"ser"}, .{"si"}, .{"sido"}, .{"siendo"}, .{"sin"}, .{"sobre"}, .{"sois"}, .{"somos"},
    .{"son"}, .{"soy"}, .{"su"}, .{"sus"}, .{"suya"}, .{"suyo"}, .{"tambien"}, .{"tanto"}, .{"te"}, .{"tenemos"},
    .{"tener"}, .{"tengo"}, .{"ti"}, .{"tiene"}, .{"tienen"}, .{"todo"}, .{"todos"}, .{"tu"}, .{"tus"}, .{"tuya"},
    .{"tuyo"}, .{"un"}, .{"una"}, .{"uno"}, .{"unos"}, .{"vosotras"}, .{"vosotros"}, .{"vuestra"}, .{"vuestro"}, .{"y"},
    .{"ya"}, .{"yo"},
});

const hungarian_stopwords = std.StaticStringMap(void).initComptime(.{
    .{"a"}, .{"ahogy"}, .{"ahol"}, .{"aki"}, .{"akik"}, .{"akkor"}, .{"alatt"}, .{"altal"}, .{"amely"}, .{"amelyek"},
    .{"ami"}, .{"amit"}, .{"amolyan"}, .{"amikor"}, .{"ahol"}, .{"arra"}, .{"az"}, .{"azok"}, .{"azon"}, .{"azonban"},
    .{"azt"}, .{"aztán"}, .{"azután"}, .{"azzal"}, .{"be"}, .{"belul"}, .{"benne"}, .{"cikk"}, .{"cikkek"}, .{"csak"},
    .{"de"}, .{"e"}, .{"ebben"}, .{"eddig"}, .{"egesz"}, .{"egy"}, .{"egyes"}, .{"egyetlen"}, .{"egyik"}, .{"egyre"},
    .{"ehhez"}, .{"ekkor"}, .{"el"}, .{"eleg"}, .{"ellen"}, .{"elo"}, .{"elott"}, .{"első"}, .{"emilyen"}, .{"en"},
    .{"ennek"}, .{"erre"}, .{"ez"}, .{"ezek"}, .{"ezen"}, .{"ezt"}, .{"ezzel"}, .{"fel"}, .{"fele"}, .{"felé"},
    .{"hanem"}, .{"hiszen"}, .{"hogy"}, .{"hogyan"}, .{"igen"}, .{"ill"}, .{"illetve"}, .{"ilyen"}, .{"ilyenkor"}, .{"ison"},
    .{"isonnan"}, .{"itt"}, .{"jobban"}, .{"jó"}, .{"jól"}, .{"kell"}, .{"kellett"}, .{"keressunk"}, .{"keresztul"}, .{"ki"},
    .{"kívul"}, .{"kozott"}, .{"kozul"}, .{"legalabb"}, .{"lehet"}, .{"lehetett"}, .{"lenne"}, .{"lenni"}, .{"lesz"}, .{"lett"},
    .{"maga"}, .{"magat"}, .{"majd"}, .{"meg"}, .{"mellett"}, .{"mert"}, .{"mi"}, .{"mikor"}, .{"milyen"}, .{"minden"},
    .{"mindenki"}, .{"mindent"}, .{"mindig"}, .{"mint"}, .{"mintha"}, .{"mit"}, .{"mivel"}, .{"miért"}, .{"most"}, .{"na"},
    .{"nagy"}, .{"nagyobb"}, .{"nagyon"}, .{"ne"}, .{"nekem"}, .{"neki"}, .{"nem"}, .{"nincs"}, .{"néha"}, .{"nélkul"},
    .{"o"}, .{"oda"}, .{"ok"}, .{"oket"}, .{"olyan"}, .{"ott"}, .{"pedig"}, .{"persze"}, .{"rá"}, .{"s"},
    .{"saját"}, .{"sem"}, .{"semmi"}, .{"sok"}, .{"sokat"}, .{"sokkal"}, .{"szamara"}, .{"szemben"}, .{"szerint"}, .{"szinte"},
    .{"talán"}, .{"tehát"}, .{"teljes"}, .{"tovább"}, .{"továbbá"}, .{"több"}, .{"ugyanis"}, .{"után"}, .{"utolsó"}, .{"vagy"},
    .{"vagyis"}, .{"valaki"}, .{"valami"}, .{"valamint"}, .{"való"}, .{"van"}, .{"vannak"}, .{"vele"}, .{"vissza"}, .{"viszont"},
    .{"volna"}, .{"volt"}, .{"voltak"}, .{"voltam"}, .{"voltunk"}, .{"által"}, .{"át"}, .{"én"}, .{"éppen"}, .{"és"},
    .{"így"}, .{"ön"}, .{"össze"}, .{"úgy"}, .{"új"}, .{"újabb"}, .{"újra"},
});

const italian_stopwords = std.StaticStringMap(void).initComptime(.{
    .{"ad"}, .{"al"}, .{"allo"}, .{"ai"}, .{"agli"}, .{"all"}, .{"agl"}, .{"alla"}, .{"alle"}, .{"con"},
    .{"col"}, .{"coi"}, .{"da"}, .{"dal"}, .{"dallo"}, .{"dai"}, .{"dagli"}, .{"dall"}, .{"dagl"}, .{"dalla"},
    .{"dalle"}, .{"di"}, .{"del"}, .{"dello"}, .{"dei"}, .{"degli"}, .{"dell"}, .{"degl"}, .{"della"}, .{"delle"},
    .{"in"}, .{"nel"}, .{"nello"}, .{"nei"}, .{"negli"}, .{"nell"}, .{"negl"}, .{"nella"}, .{"nelle"}, .{"su"},
    .{"sul"}, .{"sullo"}, .{"sui"}, .{"sugli"}, .{"sull"}, .{"sugl"}, .{"sulla"}, .{"sulle"}, .{"per"}, .{"tra"},
    .{"contro"}, .{"io"}, .{"lo"}, .{"lei"}, .{"lui"}, .{"noi"}, .{"voi"}, .{"loro"}, .{"mio"}, .{"mia"},
    .{"miei"}, .{"mie"}, .{"tuo"}, .{"tua"}, .{"tuoi"}, .{"tue"}, .{"suo"}, .{"sua"}, .{"suoi"}, .{"sue"},
    .{"nostro"}, .{"nostra"}, .{"nostri"}, .{"nostre"}, .{"vostro"}, .{"vostra"}, .{"vostri"}, .{"vostre"}, .{"mi"}, .{"ti"},
    .{"ci"}, .{"vi"}, .{"si"}, .{"questo"}, .{"quello"}, .{"che"}, .{"chi"}, .{"non"}, .{"più"}, .{"quale"},
    .{"quanto"}, .{"quanti"}, .{"quanta"}, .{"quante"}, .{"quello"}, .{"quelli"}, .{"quella"}, .{"quelle"}, .{"come"}, .{"dove"},
    .{"quando"}, .{"sono"}, .{"sei"}, .{"siamo"}, .{"siete"}, .{"sia"}, .{"siate"}, .{"siano"}, .{"avere"}, .{"ho"},
    .{"hai"}, .{"ha"}, .{"abbiamo"}, .{"avete"}, .{"hanno"}, .{"abbia"}, .{"abbiate"}, .{"abbiano"}, .{"essere"}, .{"era"},
    .{"eri"}, .{"eravamo"}, .{"eravate"}, .{"erano"}, .{"fui"}, .{"fosti"}, .{"fu"}, .{"fummo"}, .{"foste"}, .{"furono"},
    .{"fossi"}, .{"fosse"}, .{"fossimo"}, .{"fossero"}, .{"avessi"}, .{"avesse"}, .{"avessimo"}, .{"avessero"}, .{"avrò"}, .{"avrai"},
    .{"avrà"}, .{"avremo"}, .{"avrete"}, .{"avranno"}, .{"avrei"}, .{"avresti"}, .{"avrebbe"}, .{"avremmo"}, .{"avreste"}, .{"avrebbero"},
});

const portuguese_stopwords = std.StaticStringMap(void).initComptime(.{
    .{"de"}, .{"a"}, .{"o"}, .{"que"}, .{"e"}, .{"do"}, .{"da"}, .{"em"}, .{"um"}, .{"para"},
    .{"com"}, .{"não"}, .{"uma"}, .{"os"}, .{"no"}, .{"se"}, .{"na"}, .{"por"}, .{"mais"}, .{"as"},
    .{"dos"}, .{"como"}, .{"mas"}, .{"foi"}, .{"ao"}, .{"ele"}, .{"das"}, .{"tem"}, .{"à"}, .{"seu"},
    .{"sua"}, .{"ou"}, .{"ser"}, .{"quando"}, .{"muito"}, .{"há"}, .{"nos"}, .{"já"}, .{"está"}, .{"eu"},
    .{"também"}, .{"só"}, .{"pelo"}, .{"pela"}, .{"até"}, .{"isso"}, .{"ela"}, .{"entre"}, .{"era"}, .{"depois"},
    .{"sem"}, .{"mesmo"}, .{"aos"}, .{"ter"}, .{"seus"}, .{"quem"}, .{"nas"}, .{"me"}, .{"esse"}, .{"eles"},
    .{"estão"}, .{"você"}, .{"tinha"}, .{"foram"}, .{"essa"}, .{"num"}, .{"nem"}, .{"suas"}, .{"meu"}, .{"às"},
    .{"minha"}, .{"têm"}, .{"numa"}, .{"pelos"}, .{"elas"}, .{"havia"}, .{"seja"}, .{"qual"}, .{"será"}, .{"nós"},
    .{"tenho"}, .{"lhe"}, .{"deles"}, .{"essas"}, .{"esses"}, .{"pelas"}, .{"este"}, .{"fosse"}, .{"dele"}, .{"ao"},
});

const dutch_stopwords = std.StaticStringMap(void).initComptime(.{
    .{"de"}, .{"en"}, .{"van"}, .{"ik"}, .{"te"}, .{"dat"}, .{"die"}, .{"in"}, .{"een"}, .{"hij"},
    .{"het"}, .{"niet"}, .{"zijn"}, .{"is"}, .{"was"}, .{"op"}, .{"aan"}, .{"met"}, .{"als"}, .{"voor"},
    .{"had"}, .{"er"}, .{"maar"}, .{"om"}, .{"hem"}, .{"dan"}, .{"zou"}, .{"of"}, .{"wat"}, .{"want"},
    .{"nog"}, .{"zal"}, .{"me"}, .{"zij"}, .{"nu"}, .{"geen"}, .{"omdat"}, .{"iets"}, .{"worden"}, .{"toch"},
    .{"al"}, .{"waren"}, .{"veel"}, .{"meer"}, .{"doen"}, .{"toen"}, .{"moet"}, .{"ben"}, .{"zonder"}, .{"kan"},
    .{"hun"}, .{"dus"}, .{"alles"}, .{"onder"}, .{"ja"}, .{"eens"}, .{"hier"}, .{"wie"}, .{"werd"}, .{"altijd"},
    .{"doch"}, .{"wordt"}, .{"wezen"}, .{"kunnen"}, .{"ons"}, .{"zelf"}, .{"tegen"}, .{"na"}, .{"reeds"}, .{"wil"},
    .{"kon"}, .{"niets"}, .{"uw"}, .{"iemand"}, .{"geweest"}, .{"andere"}, .{"naar"}, .{"haar"}, .{"mij"}, .{"over"},
});

const russian_stopwords = std.StaticStringMap(void).initComptime(.{
    .{"и"}, .{"в"}, .{"во"}, .{"не"}, .{"что"}, .{"он"}, .{"на"}, .{"я"}, .{"с"}, .{"со"},
    .{"как"}, .{"а"}, .{"то"}, .{"все"}, .{"она"}, .{"так"}, .{"его"}, .{"но"}, .{"да"}, .{"ты"},
    .{"к"}, .{"у"}, .{"же"}, .{"вы"}, .{"за"}, .{"бы"}, .{"по"}, .{"только"}, .{"ее"}, .{"мне"},
    .{"было"}, .{"вот"}, .{"от"}, .{"меня"}, .{"еще"}, .{"нет"}, .{"о"}, .{"из"}, .{"ему"}, .{"теперь"},
    .{"когда"}, .{"даже"}, .{"ну"}, .{"вдруг"}, .{"ли"}, .{"если"}, .{"уже"}, .{"или"}, .{"ни"}, .{"быть"},
    .{"был"}, .{"него"}, .{"до"}, .{"вас"}, .{"нибудь"}, .{"опять"}, .{"уж"}, .{"вам"}, .{"ведь"}, .{"там"},
    .{"потом"}, .{"себя"}, .{"ничего"}, .{"ей"}, .{"может"}, .{"они"}, .{"тут"}, .{"где"}, .{"есть"}, .{"надо"},
    .{"ней"}, .{"для"}, .{"мы"}, .{"тебя"}, .{"их"}, .{"чем"}, .{"была"}, .{"сам"}, .{"чтоб"}, .{"без"},
    .{"будто"}, .{"чего"}, .{"раз"}, .{"тоже"}, .{"себе"}, .{"под"}, .{"будет"}, .{"ж"}, .{"тогда"}, .{"кто"},
    .{"этот"}, .{"того"}, .{"потому"}, .{"этого"}, .{"какой"}, .{"совсем"}, .{"ним"}, .{"здесь"}, .{"этом"}, .{"один"},
});

pub fn stem(allocator: std.mem.Allocator, word: []const u8) ![]u8 {
    if (word.len <= 2) return allocator.dupe(u8, word);
    var buffer = try allocator.alloc(u8, word.len + 8);
    defer allocator.free(buffer);
    @memcpy(buffer[0..word.len], word);
    const length = porterStem(buffer, word.len);
    return allocator.dupe(u8, buffer[0..length]);
}

fn isConsonant(word: []const u8, index: usize) bool {
    return switch (word[index]) {
        'a', 'e', 'i', 'o', 'u' => false,
        'y' => index == 0 or !isConsonant(word, index - 1),
        else => true,
    };
}

fn measure(word: []const u8, length: usize) usize {
    if (length == 0) return 0;
    var count: usize = 0;
    var index: usize = 0;
    while (index < length and isConsonant(word, index)) : (index += 1) {}
    while (true) {
        while (index < length and !isConsonant(word, index)) : (index += 1) {}
        if (index >= length) return count;
        index += 1;
        count += 1;
        while (index < length and isConsonant(word, index)) : (index += 1) {}
        if (index >= length) return count;
    }
}

fn hasVowel(word: []const u8, length: usize) bool {
    for (word[0..length]) |byte| {
        switch (byte) {
            'a', 'e', 'i', 'o', 'u', 'y' => return true,
            else => {},
        }
    }
    return false;
}

fn endsDoubleConsonant(word: []const u8, length: usize) bool {
    if (length < 2) return false;
    return word[length - 1] == word[length - 2] and isConsonant(word, length - 1);
}

fn cvc(word: []const u8, length: usize) bool {
    if (length < 3) return false;
    if (!isConsonant(word, length - 3) or isConsonant(word, length - 2) or !isConsonant(word, length - 1)) return false;
    return switch (word[length - 1]) {
        'w', 'x', 'y' => false,
        else => true,
    };
}

fn endsWith(word: []const u8, length: usize, suffix: []const u8) bool {
    if (length < suffix.len) return false;
    return std.mem.eql(u8, word[length - suffix.len .. length], suffix);
}

fn setTo(buffer: []u8, length: usize, replacement: []const u8) usize {
    @memcpy(buffer[length..][0..replacement.len], replacement);
    return length + replacement.len;
}

fn porterStem(buffer: []u8, input_length: usize) usize {
    var length = input_length;
    if (endsWith(buffer, length, "'s")) length -= 2;
    if (endsWith(buffer, length, "sses")) {
        length -= 2;
    } else if (endsWith(buffer, length, "ies")) {
        length -= 3;
        length = setTo(buffer, length, "i");
    } else if (length >= 2 and buffer[length - 1] == 's' and buffer[length - 2] != 's' and buffer[length - 2] != 'u') {
        length -= 1;
    }
    if (endsWith(buffer, length, "eed")) {
        if (measure(buffer, length - 3) > 0) length -= 1;
    } else if ((endsWith(buffer, length, "ed") or endsWith(buffer, length, "ing")) and hasVowel(buffer, length - @as(usize, if (endsWith(buffer, length, "ed")) 2 else 3))) {
        if (endsWith(buffer, length, "ed")) {
            length -= 2;
        } else {
            length -= 3;
        }
        if (endsWith(buffer, length, "at") or endsWith(buffer, length, "bl") or endsWith(buffer, length, "iz")) {
            buffer[length] = 'e';
            length += 1;
        } else if (endsDoubleConsonant(buffer, length)) {
            length -= 1;
            if (buffer[length - 1] == 'l' or buffer[length - 1] == 's' or buffer[length - 1] == 'z') length += 1;
        } else if (measure(buffer, length) == 1 and cvc(buffer, length)) {
            buffer[length] = 'e';
            length += 1;
        }
    }
    if (length >= 2 and buffer[length - 1] == 'y' and hasVowel(buffer, length - 1)) buffer[length - 1] = 'i';
    length = step2(buffer, length);
    length = step3(buffer, length);
    length = step4(buffer, length);
    length = step5(buffer, length);
    return length;
}

fn step2(buffer: []u8, length: usize) usize {
    const pairs = [_][2][]const u8{
        .{ "ational", "ate" }, .{ "tional", "tion" }, .{ "enci", "ence" }, .{ "anci", "ance" },
        .{ "izer", "ize" }, .{ "abli", "able" }, .{ "alli", "al" }, .{ "entli", "ent" },
        .{ "eli", "e" }, .{ "ousli", "ous" }, .{ "ization", "ize" }, .{ "ation", "ate" },
        .{ "ator", "ate" }, .{ "alism", "al" }, .{ "iveness", "ive" }, .{ "fulness", "ful" },
        .{ "ousness", "ous" }, .{ "aliti", "al" }, .{ "iviti", "ive" }, .{ "biliti", "ble" },
    };
    for (pairs) |pair| {
        if (endsWith(buffer, length, pair[0])) {
            if (measure(buffer, length - pair[0].len) > 0) return setTo(buffer, length - pair[0].len, pair[1]);
            return length;
        }
    }
    return length;
}

fn step3(buffer: []u8, length: usize) usize {
    const pairs = [_][2][]const u8{
        .{ "icate", "ic" }, .{ "ative", "" }, .{ "alize", "al" }, .{ "iciti", "ic" },
        .{ "ical", "ic" }, .{ "ful", "" }, .{ "ness", "" },
    };
    for (pairs) |pair| {
        if (endsWith(buffer, length, pair[0])) {
            if (measure(buffer, length - pair[0].len) > 0) return setTo(buffer, length - pair[0].len, pair[1]);
            return length;
        }
    }
    return length;
}

fn step4(buffer: []u8, length: usize) usize {
    const suffixes = [_][]const u8{ "al", "ance", "ence", "er", "ic", "able", "ible", "ant", "ement", "ment", "ent", "ion", "ou", "ism", "ate", "iti", "ous", "ive", "ize" };
    for (suffixes) |suffix| {
        if (!endsWith(buffer, length, suffix)) continue;
        const measure_length = length - suffix.len;
        if (std.mem.eql(u8, suffix, "ion")) {
            if (measure_length == 0) return length;
            const previous = buffer[measure_length - 1];
            if (previous != 's' and previous != 't') return length;
        }
        if (measure(buffer, measure_length) > 1) return measure_length;
        return length;
    }
    return length;
}

fn step5(buffer: []u8, length: usize) usize {
    var size = length;
    if (size >= 1 and buffer[size - 1] == 'e') {
        const measure_without = measure(buffer, size - 1);
        if (measure_without > 1 or (measure_without == 1 and !cvc(buffer, size - 1))) size -= 1;
    }
    if (size >= 2 and buffer[size - 1] == 'l' and buffer[size - 2] == 'l' and measure(buffer, size - 1) > 1) size -= 1;
    return size;
}

pub const TokenList = struct {
    tokens: []Token,
    allocator: std.mem.Allocator,
    unique_terms: usize,

    pub fn release(self: TokenList) void {
        for (self.tokens) |*token| token.release(self.allocator);
        self.allocator.free(self.tokens);
    }
};

pub fn tokenize(allocator: std.mem.Allocator, text: []const u8, field: u8, options: Options) !TokenList {
    var tokens = std.ArrayList(Token).init(allocator);
    errdefer {
        for (tokens.items) |*token| token.release(allocator);
        tokens.deinit();
    }
    var unique = std.StringHashMap(void).init(allocator);
    defer unique.deinit();
    var index: usize = 0;
    var position: u32 = 0;
    var sentence: u32 = 0;
    while (index < text.len) {
        const byte = text[index];
        const length = if (byte < 0x80) 1 else (std.unicode.utf8ByteSequenceLength(byte) catch 1);
        if (std.ascii.isWhitespace(byte)) {
            index += length;
            continue;
        }
        const is_terminal = byte == '.' or byte == '!' or byte == '?' or byte == '\n';
        var end = index;
        while (end < text.len) : (end += if (text[end] < 0x80) 1 else (std.unicode.utf8ByteSequenceLength(text[end]) catch 1)) {
            const current = text[end];
            const current_length = if (current < 0x80) 1 else (std.unicode.utf8ByteSequenceLength(current) catch 1);
            if (current_length != 1) continue;
            if (std.ascii.isWhitespace(current)) break;
            if (options.split_on_punctuation and !std.ascii.isAlphanumeric(current) and current != '_' and current != '-' and current != '\'' and current != '.') break;
            if (current == '.' and end + 1 < text.len and std.ascii.isWhitespace(text[end + 1])) break;
        }
        var raw = text[index..end];
        raw = std.mem.trim(u8, raw, ".,;:!?\"'`()[]{}<>«»„“”’‘/-_");
        if (raw.len > 0 and raw.len <= options.max_token_length and raw.len >= options.min_token_length) {
            var has_letter = false;
            var has_digit = false;
            for (raw) |character| {
                if (std.ascii.isAlphabetic(character)) has_letter = true;
                if (std.ascii.isDigit(character)) has_digit = true;
            }
            if (has_letter or (options.keep_numbers and has_digit)) {
                const kind: TokenKind = if (has_letter and has_digit) .mixed else if (has_digit) .number else .word;
                if (kind != .number or options.keep_numbers) {
                    const lowered = try std.ascii.allocLowerString(allocator, raw);
                    const folded = if (options.fold_diacritics) try foldDiacritics(allocator, lowered) else try allocator.dupe(u8, lowered);
                    allocator.free(lowered);
                    const stemmed = if (options.enable_stemming and kind == .word) try stem(allocator, folded) else try allocator.dupe(u8, folded);
                    const is_stop = if (options.mark_stopwords and kind == .word) isStopword(folded, options.language) else false;
                    try tokens.append(.{
                        .text = folded,
                        .stem = stemmed,
                        .start = index,
                        .end = index + raw.len,
                        .kind = kind,
                        .field = field,
                        .position = position,
                        .sentence = sentence,
                        .stopword = is_stop,
                    });
                    try unique.put(stemmed, {});
                    position += 1;
                }
            }
        }
        if (is_terminal) sentence += 1;
        index = if (end > index) end else index + length;
    }
    return .{ .tokens = try tokens.toOwnedSlice(), .allocator = allocator, .unique_terms = unique.count() };
}

pub const TermFrequency = struct {
    term: []const u8,
    count: u32,
    first_position: u32,
};

pub fn termFrequencies(allocator: std.mem.Allocator, tokens: []const Token) ![]TermFrequency {
    var map = std.StringHashMap(usize).init(allocator);
    defer map.deinit();
    var list = std.ArrayList(TermFrequency).init(allocator);
    for (tokens) |token| {
        if (token.stopword) continue;
        if (map.get(token.stem)) |index| {
            list.items[index].count += 1;
            continue;
        }
        const term = try allocator.dupe(u8, token.stem);
        try list.append(.{ .term = term, .count = 1, .first_position = token.position });
        try map.put(term, list.items.len - 1);
    }
    std.sort.block(TermFrequency, list.items, {}, struct {
        fn gt(_: void, a: TermFrequency, b: TermFrequency) bool {
            if (a.count != b.count) return a.count > b.count;
            return std.mem.lessThan(u8, a.term, b.term);
        }
    }.gt);
    return list.toOwnedSlice();
}

pub fn releaseTermFrequencies(allocator: std.mem.Allocator, frequencies: []TermFrequency) void {
    for (frequencies) |frequency| allocator.free(frequency.term);
    allocator.free(frequencies);
}

pub fn sentences(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var out = std.ArrayList([]const u8).init(allocator);
    errdefer out.deinit();
    var start: usize = 0;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        const byte = text[index];
        if (byte != '.' and byte != '!' and byte != '?' and byte != '\n') continue;
        const next_is_space = index + 1 >= text.len or std.ascii.isWhitespace(text[index + 1]);
        if (!next_is_space) continue;
        if (index > start) {
            const slice = std.mem.trim(u8, text[start .. index + 1], " \t\r\n");
            if (slice.len > 0) try out.append(try allocator.dupe(u8, slice));
        }
        start = index + 1;
    }
    if (start < text.len) {
        const tail = std.mem.trim(u8, text[start..], " \t\r\n");
        if (tail.len > 0) try out.append(try allocator.dupe(u8, tail));
    }
    return out.toOwnedSlice();
}

pub fn releaseStrings(allocator: std.mem.Allocator, values: [][]const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

pub fn shingles(allocator: std.mem.Allocator, tokens: []const Token, size: usize) ![]u64 {
    if (tokens.len < size) return allocator.alloc(u64, 0);
    const out = try allocator.alloc(u64, tokens.len - size + 1);
    for (0..out.len) |index| {
        var digest: u64 = 0x243F6A8885A308D3;
        for (tokens[index .. index + size]) |token| digest = hashing.hash64(digest, token.stem);
        out[index] = digest;
    }
    return out;
}

pub fn detectLanguage(text: []const u8) []const u8 {
    const languages = [_][]const u8{ "en", "de", "fr", "es", "it", "pt", "nl", "ru", "hu" };
    var best: []const u8 = "en";
    var best_score: f64 = 0.0;
    var tokens = std.mem.tokenizeAny(u8, text, " \t\r\n.,;:!?\"'`()[]{}<>/\\|-_=+*&^%$#@~0123456789");
    var counts = std.StringHashMap(u32).init(std.heap.page_allocator);
    defer counts.deinit();
    var total: u32 = 0;
    while (tokens.next()) |raw| {
        if (raw.len == 0 or raw.len > 24) continue;
        const lowered = std.ascii.allocLowerString(std.heap.page_allocator, raw) catch continue;
        const entry = counts.getOrPut(lowered) catch {
            std.heap.page_allocator.free(lowered);
            continue;
        };
        if (!entry.found_existing) {
            entry.value_ptr.* = 0;
        } else {
            std.heap.page_allocator.free(lowered);
        }
        entry.value_ptr.* += 1;
        total += 1;
    }
    if (total < 8) return best;
    for (languages) |language| {
        const set = stopwordSet(language) orelse continue;
        var matched: u32 = 0;
        var iterator = counts.iterator();
        while (iterator.next()) |entry| {
            if (set.has(entry.key_ptr.*)) matched += entry.value_ptr.*;
        }
        const score = @as(f64, @floatFromInt(matched)) / @as(f64, @floatFromInt(total));
        if (score > best_score) {
            best_score = score;
            best = language;
        }
    }
    return if (best_score >= 0.02) best else "en";
}
