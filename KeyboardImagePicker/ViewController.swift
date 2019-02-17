//
//  ViewController.swift
//  KeyboardImagePicker
//
//  Created by jinsei_shima on 2019/02/09.
//  Copyright © 2019 Jinsei Shima. All rights reserved.
//

import UIKit
import Photos

import RxKeyboard
import RxSwift


enum Union2<A, B> {
    case a(A)
    case b(B)
}

final class OperationCell: UICollectionViewCell {

    private let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)

        addSubview(imageView)

        backgroundColor = .lightGray

        imageView.frame = bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.contentMode = .center
        imageView.clipsToBounds = true
    }

    func set(image: UIImage?) {
        imageView.image = image
        imageView.setNeedsDisplay()
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class ImageCell: UICollectionViewCell {

    private let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)

        addSubview(imageView)

        backgroundColor = .lightGray

        imageView.frame = bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
    }

    func set(image: UIImage?) {
        imageView.image = image
        imageView.setNeedsDisplay()
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class ImagePickerCarouselView: UIView, UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDelegateFlowLayout {

    private let collectionView: UICollectionView
    private let libraryButton = UIButton(type: .system)

    private let imageManager = PHImageManager()

    private var items: [Union2<PHAsset, Void>] = []

    override init(frame: CGRect) {

        let layout = UICollectionViewFlowLayout()
        layout.sectionInset = .init(top: 8, left: 8, bottom: 8, right: 8)
        layout.minimumInteritemSpacing = 2
        layout.minimumLineSpacing = 2
        layout.scrollDirection = .horizontal
        layout.estimatedItemSize = UICollectionViewFlowLayout.automaticSize

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)

        super.init(frame: frame)

        backgroundColor = .white

        addSubview(collectionView)
        addSubview(libraryButton)

        collectionView.backgroundColor = .white
        collectionView.alwaysBounceHorizontal = true
        collectionView.showsHorizontalScrollIndicator = true
        collectionView.translatesAutoresizingMaskIntoConstraints = false

        collectionView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: 0).isActive = true
        collectionView.leftAnchor.constraint(equalTo: leftAnchor, constant: 0).isActive = true
        collectionView.rightAnchor.constraint(equalTo: rightAnchor, constant: 0).isActive = true
        collectionView.topAnchor.constraint(equalTo: topAnchor, constant: 0).isActive = true

        collectionView.dataSource = self
        collectionView.delegate = self

        collectionView.register(ImageCell.self, forCellWithReuseIdentifier: "cell1")
        collectionView.register(OperationCell.self, forCellWithReuseIdentifier: "cell2")

        libraryButton.setImage(UIImage(named: "library"), for: .normal)
        libraryButton.imageEdgeInsets = .init(top: 8, left: 8, bottom: 8, right: 8)
        libraryButton.backgroundColor = .white
        libraryButton.layer.shadowColor = UIColor.darkGray.withAlphaComponent(0.2).cgColor
        libraryButton.layer.shadowOffset = .init(width: 0, height: 2)
        libraryButton.layer.shadowRadius = 8
        libraryButton.layer.shadowOpacity = 1

        libraryButton.translatesAutoresizingMaskIntoConstraints = false
        libraryButton.leftAnchor.constraint(equalTo: leftAnchor, constant: 16).isActive = true
        libraryButton.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -16).isActive = true

        libraryButton.addTarget(self, action: #selector(didTapButton), for: .touchUpInside)

        autoresizingMask = [.flexibleWidth, .flexibleHeight]

        setup()
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }


    override func layoutSubviews() {
        super.layoutSubviews()

        libraryButton.layer.cornerRadius = libraryButton.bounds.width / 2
        
    }

    @objc func didTapButton() {
        print("tap library button")
    }

    private func setup() {

        libraryRequestAuthorization()

        items.append(.b(()))

        let result = PHAsset.fetchAssets(with: .image, options: nil)
        result.enumerateObjects { [weak self] (obj, index, stop) in
            self?.items.append(.a(obj))
        }

        collectionView.reloadData()
    }

    // カメラロールへのアクセス許可
    fileprivate func libraryRequestAuthorization() {
        PHPhotoLibrary.requestAuthorization({ status in
            switch status {
            case .authorized:
                print("authorized")
            case .denied:
                print("denied")
            case .notDetermined:
                print("NotDetermined")
            case .restricted:
                print("Restricted")
            }
        })
    }


    // MARK: UICollectionViewDataSource

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {

        let item = items[indexPath.row]

        switch item {
        case .a(let a):

            guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "cell1", for: indexPath) as? ImageCell else {
                return UICollectionViewCell() }

            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.version = .current
            options.resizeMode = .exact

            imageManager
                .requestImage(
                    for: a,
                    targetSize: cell.bounds.size,
                    contentMode: .aspectFill,
                    options: nil,
                    resultHandler: { image, info in
                        cell.set(image: image)
                })
            return cell

        case .b:

            guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "cell2", for: indexPath) as? OperationCell else { return UICollectionViewCell() }

            cell.set(image: UIImage(named: "library"))
            return cell
        }
    }


    // MARK: UICollectionViewDelegate


    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {

        let item = items[indexPath.row]

        switch item {
        case .a(let a):
            #warning("open image confirmation screen")
        case .b(let b):
            #warning("open image library screen")
        }

    }

    // MARK: UICollectionViewDelegateFlowLayout

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {

        guard let layout = collectionViewLayout as? UICollectionViewFlowLayout else { return .zero }

        let length = (collectionView.bounds.height - layout.sectionInset.top - layout.sectionInset.bottom - layout.minimumLineSpacing) / 2
        return .init(width: length, height: length)
    }
}


class MessageView: UIView, UITextViewDelegate {

    private let libraryButton = UIButton(type: .system)
    private let cameraButton = UIButton(type: .system)
    private let textView = UITextView()
    private let sendButton = UIButton(type: .system)

    private let imagePickerCarouselView = ImagePickerCarouselView(frame: .zero)

    override var canBecomeFirstResponder: Bool {
        return true
    }

    enum KeyboardType {
        case keyboard, imagePicker
    }

    var keyboardType: KeyboardType = .keyboard {
        didSet {
            reloadInputViews()
        }
    }

    override var inputView: UIView? {
        switch keyboardType {
        case .keyboard:
            return nil
        case .imagePicker:
            return imagePickerCarouselView
        }
    }

    @objc func tapLibraryButton() {

        keyboardType = .imagePicker

        becomeFirstResponder()
    }

    func textViewShouldBeginEditing(_ textView: UITextView) -> Bool {

        keyboardType = .keyboard

        return true
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = .white

        addSubview(cameraButton)
        addSubview(libraryButton)
        addSubview(textView)
        addSubview(sendButton)

        cameraButton.setImage(UIImage.init(named: "camera"), for: .normal)
        cameraButton.translatesAutoresizingMaskIntoConstraints = false

        libraryButton.setImage(UIImage.init(named: "library"), for: .normal)
        libraryButton.translatesAutoresizingMaskIntoConstraints = false
        libraryButton.addTarget(self, action: #selector(tapLibraryButton), for: .touchUpInside)

        textView.delegate = self
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.font = UIFont.systemFont(ofSize: 18, weight: .regular)

        sendButton.setTitle("Send", for: .normal)
        sendButton.titleLabel?.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
        sendButton.translatesAutoresizingMaskIntoConstraints = false


        [
            cameraButton.leftAnchor.constraint(equalTo: leftAnchor, constant: 16),
            cameraButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),

            libraryButton.leftAnchor.constraint(equalTo: cameraButton.rightAnchor, constant: 8.0),
            libraryButton.centerYAnchor.constraint(equalTo: cameraButton.centerYAnchor),

            textView.leftAnchor.constraint(equalTo: libraryButton.rightAnchor, constant: 8),
            textView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),

            sendButton.leftAnchor.constraint(equalTo: textView.rightAnchor, constant: 8),
            sendButton.centerYAnchor.constraint(equalTo: cameraButton.centerYAnchor),
            sendButton.rightAnchor.constraint(equalTo: rightAnchor, constant: -16)
            ]
            .forEach { $0.isActive = true }

    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
}



class ViewController: UIViewController {

    private let disposeBag = DisposeBag()

    private let messageInputView = MessageView(frame: .zero)


    @objc func tap() {
        messageInputView.endEditing(false)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = UIColor.groupTableViewBackground


        view.addSubview(messageInputView)

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(tap))
        view.addGestureRecognizer(tapGesture)

        messageInputView.translatesAutoresizingMaskIntoConstraints = false

        [
            messageInputView.leftAnchor.constraint(equalTo: view.leftAnchor, constant: 0),
            messageInputView.rightAnchor.constraint(equalTo: view.rightAnchor, constant: 0),
            messageInputView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: 0)
            ]
            .forEach { $0.isActive = true }


        var constraint1: NSLayoutConstraint? = nil
        var constraint2: NSLayoutConstraint? = nil

        RxKeyboard
            .instance
            .visibleHeight
            .drive(onNext: { [weak self] keyboardVisibleHeight in

                guard let self = self else { return }

                constraint1?.isActive = false
                constraint1 = nil

                constraint2?.isActive = false
                constraint2 = nil

                if keyboardVisibleHeight <= 0 {
                    constraint1 = self.messageInputView.bottomAnchor.constraint(
                        equalTo: self.view.safeAreaLayoutGuide.bottomAnchor,
                        constant: -keyboardVisibleHeight
                        )
                } else {
                    constraint2 = self.messageInputView.bottomAnchor.constraint(
                        equalTo: self.view.bottomAnchor,
                        constant: -keyboardVisibleHeight
                        )
                }
                constraint1?.isActive = true
                constraint2?.isActive = true

                self.view.layoutIfNeeded()

            })
            .disposed(by: disposeBag)

    }


}

