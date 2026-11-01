// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// What the sound keys add to the corrector, measured on common first names, surnames and product names of each language:
/// the pairs that only the key brings together, too far apart in spelling for the edit distance the corrector allows. Each
/// is a suggestion made on sound alone, and every one listed was checked to sound alike in that language. A rule change
/// that adds a pair must show it does ("Jacquet" is not "Jack"); one that loses a pair loses a misrecognition it caught.
@Suite("Knowledge · sound keys, measured")
struct PhoneticKeysPrecisionTests {
    static let names: [String: String] = [
        "en": """
        James John Robert Michael William David Richard Joseph Thomas Charles Christopher Daniel Matthew Anthony Mark Donald
        Steven Stephen Paul Andrew Joshua Kenneth Kevin Brian Bryan George Timothy Ronald Edward Jason Jeffrey Geoffrey Ryan
        Jacob Gary Nicholas Nicolas Eric Erik Jonathan Larry Justin Scott Brandon Benjamin Samuel Gregory Alexander Frank
        Patrick Raymond Jack Dennis Jerry Tyler Aaron Jose Adam Nathan Henry Douglas Zachary Peter Kyle Ethan Walter Noah
        Jeremy Christian Keith Roger Terry Gerald Harold Sean Shawn Shaun Austin Carl Karl Arthur Lawrence Laurence Dylan
        Dillon Jesse Jordan Bryce Billy Bruce Gabriel Logan Albert Willie Alan Allen Allan Juan Wayne Elijah Randy Vincent
        Ralph Eugene Russell Bobby Mason Philip Phillip Louis Lewis Harry Mary Patricia Jennifer Linda Elizabeth Barbara
        Susan Jessica Sarah Sara Karen Caren Nancy Lisa Betty Margaret Sandra Ashley Kimberly Emily Donna Michelle Dorothy
        Carol Carole Amanda Melissa Deborah Debra Stephanie Rebecca Sharon Laura Cynthia Kathleen Shirley Angela Helen Anna
        Hannah Brenda Pamela Nicole Emma Samantha Katherine Catherine Kathryn Christine Kristine Debbie Rachel Carolyn Janet
        Maria Heather Diane Dianne Ruth Julie Olivia Joyce Virginia Victoria Kelly Kelli Lauren Christina Joan Evelyn
        Judith Megan Meghan Andrea Cheryl Sheryl Jacqueline Martha Gloria Teresa Theresa Anne Madison Frances Janice Jean
        Jeanne Abigail Alice Julia Judy Sophia Sofia Grace Denise Amber Doris Marilyn Danielle Beverly Isabella Diana
        Natalie Brittany Charlotte Marie Kayla Alexis Kathy Cathy Katie Kate Claire Clare Chloe Khloe Caitlin Kaitlyn
        Katelyn Lindsay Lindsey Jasmine Yasmin Leah Leigh Aiden Aidan Jayden Jaden Ivan Evan Owen Liam Luke Lucas Mack
        Jake Mike Mick Nick Rick Rich Chris Kris Phil Bill Will Steve Seth Beth Kristen Kirsten Christen Kristin Tristan
        Dustin Weston Preston Colin Collin Conor Connor Cameron Kameron Carter Parker Hunter Cooper Jackson Jaxon Hudson
        Grayson Greyson Brayden Braden Easton Chase Cole Kole Wyatt Elliott Eliot Lincoln Josiah Isaac Isaak Ezra Asher
        Silas Jude Theo Levi Miles Myles Ezekiel Nolan Roman Ryder Rider Smith Smyth Johnson Jonson Williams Brown Jones
        Miller Muller Davis Wilson Anderson Andersen Taylor Tailor Moore Martin Thompson Thomson Tomson White Harris Clark
        Clarke Robinson Walker Young King Wright Torres Hill Green Greene Adams Nelson Baker Hall Campbell Mitchell
        Roberts Phillips Philips Evans Turner Collins Edwards Stewart Stuart Morris Murphy Cook Cooke Rogers Morgan Peterson
        Petersen Reed Reid Read Bailey Bell Howard Ward Richardson Wood Watson Brooks Bennett Gray Grey Hughes Price Myers
        Meyers Long Foster Sanders Ross Powell Sullivan Jenkins Perry Butler Barnes Fisher Fischer Henderson Coleman Simmons
        Patterson Reynolds Hamilton Graham Wallace Griffin West Hayes Gibson Bryant Ellis Stevens Stephens Murray Ford
        Marshall Owens McDonald MacDonald Harrison Kennedy Wells Woods Olson Olsen Webb Washington Tucker Freeman Burns
        Snyder Schneider Simpson Crawford Porter Shaw Gordon Wagner Hicks Dixon Hunt Palmer Robertson Black Holmes Stone
        Meyer Boyd Mills Warren Rose Rice Schmidt Patel Ferguson Nichols Nicholls Weaver Daniels Stephenson Stevenson Knight
        Kubernetes Cobalt Kafka Jira Confluence Figma Notion Github Gitlab Salesforce Hubspot Zendesk Stripe Shopify Twilio
        Datadog Grafana Prometheus Terraform Ansible Docker Postgres Redis Mongo Snowflake Databricks Tableau Looker Okta
        Vercel Netlify Heroku Azure Oracle Cisco Qualcomm Nvidia Intel Xerox Zebra Phoenix Quantum Kinetic Cinema Sigma
        Cygnus Chronos Kronos Cobaltix Kobaltix Acme Northwind Contoso Fabrikam Initech Globex Umbrella Wayne Stark Hooli
        Chase Citi Sears Kmart Costco Target Lyft Uber Airbnb Expedia Booking Philips Siemens Bosch Nokia Ericsson Sony
        Canon Nikon Kodak Xbox Cyber Psyche Phase Faze Kase Case Kane Cain Caine Kaine Shane Shayne Jane Jaine Wade Waid
        Ben Tom Tim Kim Jim Ken Kent Kurt Curt Jon Don Dan Ron Rob Bob Matt Nate Pete Tony Max Mac Jay Ray Rae Sam Leo
        """,
        "fr": """
        Jean Jeanne Pierre Michel Michelle Philippe Philip Alain Nicolas Nicole Christophe Christian Christiane Patrick
        Daniel Danielle Bernard Frédéric Frédérique Eric Laurent Lauran Stéphane Stéphanie Pascal Pascale David Julien
        Julienne Sébastien Thomas Olivier Thierry Tierry Nathalie Isabelle Sylvie Catherine Françoise François Martine Martin
        Christine Monique Valérie Sandrine Sophie Céline Chantal Véronique Anne Anna Marie Mario Sandra Hélène Elene
        Caroline Aurélie Émilie Camille Julie Julia Claire Clair Clara Laura Laure Léa Léo Lucas Louis Louise Lucie
        Hugo Arthur Gabriel Raphaël Rafael Jules Adam Nathan Paul Paula Théo Tom Ethan Mathis Mathieu Matthieu Matteo
        Maxime Antoine Alexandre Baptiste Romain Romane Simon Simone Adrien Adrienne Damien Valentin Valentine Quentin
        Kevin Florian Florence Benoît Benoit Arnaud Arnaut Renaud Reno Thibaut Tibo Thibault Gauthier Gautier Gérard Gerar
        Jacques Jack Jacquet Rose Roze Yann Yan Yves Ives Germain Germaine Sylvain Silvain Silvin Vincent Vinsan Clément
        Clemant Étienne Etiene Emmanuel Emanuel Manon Marion Océane Inès Agnès Margaux Margot Chloé Zoé Lou Jade Emma Léna
        Lena Alice Inès Ambre Juliette Mathilde Louna Romy Eva Rémi Rémy Rene René Renée Denis Denise Didier Gilles Gilbert
        Guy Guillaume Hervé Jérôme Gérôme Joël Joëlle Lionel Ludovic Marc Marcel Marcelle Mickaël Michael Olivia Patrice
        Raymond Roger Serge Sylvestre Xavier Yannick Bruno Cédric Fabrice Fabien Fabienne Franck Grégory Grégoire Henri
        Henry Jérémy Jordan Loïc Maël Morgan Noël Noëlle Pascaline Régis Thierry Valère Vivien Vivienne Dubois Durand
        Dupont Dupond Lefebvre Lefèvre Leroy Moreau Morel Laurent Simon Michel Leclerc Leclercq Rousseau Fournier Girard
        Bonnet Mercier Blanc Guérin Boyer Garnier Chevalier François Legrand Gauthier Gautier Perrin Robin Clément Morin
        Nicolas Henry Roussel Mathieu Gaillard Gaillot Renard Renaud Arnaud Arnault Faure Fort Rolland Roland Brun
        Kobaltix Cobaltix Cinéma Kinéma Quantum Phénix Fénix Thalès Talès Michelin Peugeot Renault Citroën Total Orange
        Jacquet Huet Benet Moret Fouquet Perret Michelet Ballet Boulet Cadet Thibault Perrault Foucault Arnault Hérault Herault
        Davi Alfred Félix Alix Max Deschamps Champ Leloup Loup Lacroix Delacroix Roux Leroux Giroux Lopez Lopes Ernest Scott
        Proust Faust Robert Albert Hubert Lambert Boucher Berger Bergé Granger Boulanger Olivier Didier Mercier Fournier Garnier
        Poirier Boyer Esther Peter Walter Werner Rogé Gauti Pujol Puyol Cartier Carthier Lemaire Lemerre Mallet Malet Malé
        Dumas Duma Thomas Toma Petit Peti Bertrand Bertran Durand Duran Edmond Edmon Rolland Bastien Bastian Lucien Luciane
        Fabrice Fabris Maurice Moris Morice Brice Bryce Agnès Annie Inès Ines Alexis Alexi Clovis Marcus Marcos Jules Jule
        """,
        "it": """
        Marco Marta Giuseppe Giovanni Giovani Antonio Mario Maria Luigi Francesco Francesca Angelo Angela Vincenzo Vincenza
        Pietro Salvatore Carlo Carla Franco Franca Domenico Bruno Paolo Paola Michele Mikele Michela Giorgio Giorgia
        Alessandro Alesandro Alessandra Luca Lucia Matteo Mateo Andrea Lorenzo Lorenza Leonardo Gabriele Gabriella Riccardo
        Ricardo Tommaso Tomaso Edoardo Federico Federica Federiko Davide Giacomo Jacopo Iacopo Emanuele Emanuela Simone
        Simona Filippo Filippa Stefano Stefania Chiara Kiara Giulia Giulio Sofia Sophia Aurora Alice Ginevra Beatrice
        Martina Martino Emma Greta Anna Ana Elena Elisa Laura Lara Sara Sarah Valentina Valentino Silvia Cecilia Cecillia
        Gino Gina Nino Nina Pino Rita Rosa Rossi Rosi Russo Ferrari Esposito Bianchi Romano Colombo Ricci Marino Greco
        Bruno Gallo Conti Costa Giordano Mancini Rizzo Lombardi Moretti Barbieri Fontana Santoro Mariani Rinaldi Caruso
        Ferrara Galli Martini Leone Longo Gentile Martinelli Vitale Lombardo Serra Coppola Ghiberti Giberti Chigi Cigi
        Cicchetti Ciccetti Scherzo Sciarra Schiavo Sciavo Gigli Gilli Agnelli Anelli Ghezzi Gezzi Cherubini Kerubini
        Kobaltix Cobaltix Christopher Cristofer Thomas Tomas Philip Filip Jessica Gessica Jenny Genny Jacqueline Giaclin
        Cinzia Cinthia Gianni Giani Gianluca Gianna Giada Jada Ilaria Ilario Irene Ivana Ivano Massimo Massima Nicola
        Nicoletta Oscar Ottavio Patrizia Patrizio Raffaele Raffaella Rafaele Roberto Roberta Sergio Sergia Teresa Tereza
        """,
        "pt": """
        João Joana José Josefa Antônio Antônia Francisco Francisca Carlos Carla Paulo Paula Pedro Lucas Luiz Luis Luís Luiza
        Luísa Luisa Marcos Marcus Gabriel Gabriela Rafael Rafaela Raphael Daniel Daniela Marcelo Marcela Bruno Eduardo
        Felipe Filipe Phelipe Rodrigo Manoel Manuel Ricardo Fernando Fernanda Fábio Fabio Jorge Leonardo Gustavo Guilherme
        Guilerme Mateus Matheus Thiago Tiago Henrique Enrique Diego Vinícius Vinicius Igor Ígor Davi David Arthur Artur
        Heitor Bernardo Samuel Theo Teo Lorenzo Miguel Enzo Murilo Wellington Welington Washington Uóxinton Maria Ana Anna
        Francisca Antônia Adriana Juliana Márcia Marcia Aline Sandra Camila Kamila Amanda Bruna Jéssica Jessica Letícia
        Leticia Júlia Julia Luciana Luana Mariana Vanessa Patrícia Patricia Beatriz Larissa Laryssa Natália Natalia Isabela
        Isabella Thaís Taís Tais Kauã Cauã Kauan Cauan Yasmin Iasmin Jasmin Cecília Secilia Cecilia Sofia Sophia Helena
        Elena Alice Laura Valentina Heloísa Heloisa Elóa Eloá Lívia Livia Lorena Teresa Tereza Thereza Rosa Roza Xavier
        Chavier Joaquim Joakin Joaquin Silva Santos Oliveira Souza Sousa Rodrigues Ferreira Alves Pereira Lima Gomes Costa
        Ribeiro Martins Carvalho Almeida Lopes Soares Fernandes Vieira Barbosa Rocha Dias Nascimento Andrade Moreira Nunes
        Marques Machado Mendes Freitas Cardoso Ramos Gonçalves Gonçalvez Santana Teixeira Brasil Brazil Kobaltix Cobaltix
        Cristina Christina Kristina Ester Esther Rute Ruth Edite Edith Judite Judith Neusa Neuza Sueli Suely Rosely Roseli
        """,
    ]

    static let soundOnly: [String: Set<String>] = [
        "en": [
            "chris~kris", "chronos~kronos", "eliot~elliott", "faze~phase", "jackson~jaxon", "sofia~sophia",
        ],
        "fr": [
            "arnaud~arnault", "daniel~danielle", "faure~fort", "fenix~phenix", "frederic~frederique", "jack~jacques",
            "joel~joelle", "lauran~laurent", "male~mallet", "marcel~marcelle", "margaux~margot", "maurice~morice",
            "michel~michelle", "noel~noelle", "philip~philippe", "rafael~raphael", "renaud~renault", "renaud~reno",
            "renault~reno", "silvin~sylvain", "thibault~tibo", "thibaut~tibo", "thomas~toma", "vincent~vinsan",
        ],
        "it": [
            "chiara~kiara", "christopher~cristofer", "filip~philip", "michele~mikele", "sofia~sophia",
        ],
        "pt": [
            "chavier~xavier", "felipe~phelipe", "joakin~joaquim", "joakin~joaquin", "rafael~raphael", "sofia~sophia",
            "teresa~thereza",
        ],
    ]

    @Test(arguments: ["en", "fr", "it", "pt"])
    func pairsOnlyTheSoundFinds(_ language: String) {
        // Spelled as listed (French accents count), compared as the corrector does: both 4+ letters, and beyond the edit
        // distance it allows the word heard, 1, or 2 from 7 letters.
        var written: [String: String] = [:]
        for word in Self.names[language]!.split(whereSeparator: \.isWhitespace).map(String.init) {
            if written[TextKeys.norm(word)] == nil { written[TextKeys.norm(word)] = word }
        }
        var byKey: [String: [String]] = [:]
        for (norm, word) in written {
            if let key = PhoneticKeys.key(word, language: language) { byKey[key, default: []].append(norm) }
        }
        var found: Set<String> = []
        for members in byKey.values {
            for a in members {
                for b in members where a < b && a.count >= 4 && b.count >= 4 {
                    let d = TextKeys.editDistance(a, b, limit: 2)
                    if d > (a.count >= 7 ? 2 : 1) || d > (b.count >= 7 ? 2 : 1) { found.insert("\(a)~\(b)") }
                }
            }
        }
        let expected = Self.soundOnly[language]!
        #expect(found == expected, "new: \(found.subtracting(expected).sorted()), lost: \(expected.subtracting(found).sorted())")
    }
}
