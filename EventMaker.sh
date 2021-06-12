#!/bin/bash

###################
#### Setup ########
###################
EVENT_NAME="At the Westminster Dog Show which group will the Best in Show winner come from?"
SRC_NAME="WestminsterDogs"
CATEGORY="other"
SLUG="PedigreeVsPedigreeChum"
NUMBER_OF_CARDS="7"
CARD0="Herding"
CARD1="Hound"
CARD2="Non Sporting"
CARD3="Sporting"
CARD4="Terrier"
CARD5="Toy"
CARD6="Working"
CARD7="Germany"
CARD8="Greece"
CARD9="Iceland"
CARD10="Israel"
CARD11="Italy"
CARD12="Lithuania"
CARD13="Malta"
CARD14="Moldova"
CARD15="Norway"
CARD16="Portugal"
CARD17="Russia"
CARD18="San Marino"
CARD19="Serbia"
CARD20="Spain"
CARD21="Sweden"
CARD22="Switzerland"
CARD23="The Netherlands"
CARD24="Ukraine"
CARD25="United Kingdom"
CDN="https://cdn.realitycards.io/"
IMAGES="images/"
IMAGE_FORMAT=".jpg"
NFT="nftmetadata/"
##################

mkdir -p events/$SRC_NAME
eventJSON='{\n  "name": "'$EVENT_NAME'",'
eventJSON=$eventJSON'\n  "slug": "'$SLUG'",'
eventJSON=$eventJSON'\n  "category": "'$CATEGORY'",'
eventJSON=$eventJSON'\n  "cards": {'
for ((i=0;i<$NUMBER_OF_CARDS;i++))
do
    card='CARD'$i
    eventJSON=$eventJSON'\n    "'$i'": {'
    eventJSON=$eventJSON'\n      "image": "'$CDN$IMAGES$SRC_NAME'/'${!card// /-}$IMAGE_FORMAT'",'
    eventJSON=$eventJSON'\n      "name": "'${!card}'"'
    if [ $i -lt "$(($NUMBER_OF_CARDS-1))" ]
    then
        eventJSON=$eventJSON'\n    },'
    else
        eventJSON=$eventJSON'\n    }'
    fi
done
eventJSON=$eventJSON'\n  }'
eventJSON=$eventJSON'\n}'

echo -e "$eventJSON" > events/$SRC_NAME/event.json

# now make the token.json files

for ((i=0;i<$NUMBER_OF_CARDS;i++))
do
card='CARD'$i
cardJSON='{\n  "name": "'${!card}'",'
cardJSON=$cardJSON'\n  "description": "This token represents a stake in the outcome '"'"$EVENT_NAME"'"
cardJSON=$cardJSON' at Reality Cards, the planet'"'"'s first NFT-based prediction market",'
cardJSON=$cardJSON'\n  "image": "'$CDN$IMAGES$SRC_NAME'/'${!card// /-}$IMAGE_FORMAT'",'
cardJSON=$cardJSON'\n  "affiliation": "Reality Cards"'
cardJSON=$cardJSON'\n}'

echo -e "$cardJSON" > events/$SRC_NAME/token$i.json
done